#!/bin/bash

# SRCDIR=/data/ulbms/DA-NRW_VL-Retro_SIP

# define variables
USER=""
PASSWD=""
INGESTSERVER=""
INGESTUSER=""
SRCDIR=""
DSTDIR=""
PROTOC=$SRCDIR/protokoll.log
WPROTOC=$SRCDIR/unklar.log
ALERTCOUNT=3

if [ -f $SRCDIR/.lock ]; then
   prid=`ps -p \`cat $SRCDIR/.lock\` | tail -1`
   if [ -n "$prid" ]; then
     exit
   fi
fi

# check for correct right to access and use protocol.log
if [ ! -f $PROTOC -a ! -r $PROTOC -a ! -w $PROTOC ]; then
   touch $PROTOC
elif [ ! -r $PROTOC -o ! -w $PROTOC ]; then
   echo "Protokolldatei hat falsche Rechte"
   exit
fi

if [ ! -f $WPROTOC ]; then
   touch $WPROTOC
elif [ ! -r $WPROTOC -o ! -w $WPROTOC ]; then
   echo "Protokolldatei hat falsche Rechte"
   exit
fi

if [ -z $ALERTCOUNT ]; then
   echo "Counter muss gesetzt werden"
   exit
fi

# check if user is within the vls group
usergroup=`id -gn`
if [ ! "$usergroup" = "vls" ]; then
   echo "Script kann nur von der Benutzergruppe vls ausgefuehrt werden!"
   exit
fi

# function tests if filename already exists in unklar.log
# if so ?
ProblemAnalyse(){
   if [ -n "`grep $targetfilename $WPROTOC`" ]; then
      count=`grep $targetfilename $WPROTOC | cut -d" " -f2`
      (echo "g/${targetfilename}.*/d"; echo 'wq') | ex -s $WPROTOC
      if ((( $count % 3 == 0 )) && (( $count > 0 ))) ; then
        PFILELIST="$PFILELIST\n $targetfilename  $count"
      fi
      echo "$targetfilename $((count +1))" >> $WPROTOC
   else
      echo "$targetfilename 0" >> $WPROTOC
   fi
}

for file in `ls -tra $SRCDIR/urn*zip`; do
  # lokaler Dateiname ohne Pfad
  filename=`basename $file`
  # Dateiname fuer DA-NRW (nur URN)
  targetfilename=`basename $file | cut -d"_" -f1`
  # Version der lokalen Datei (master=1, fuer delta => gen1 wird zu 2, gen2 zu 3.....)
  fileversion=`echo $filename | perl -e ' while ( <> ) { $filename=$_; if($filename=~m/.*master.*/){print 1;} 
                                                                       else { $filename=~m/.*_gen([1-9]*)_.*$/;$version=$1; print ++$version;} }'`
  #echo $fileversion
  urn=`echo $targetfilename | sed -e 's/+/\:/g'`
  #echo "URN: $urn"
  statusline=`curl -H "Accept: application/json" -u $USER:$PASSWD -s --url "https://$INGESTSERVER/daweb3/status/index?urn=$urn"`
  targetfilename=$targetfilename.zip

  echo "------"
  echo ""
  echo "Information über den Status für SIP $filename: "
  echo $statusline
  # Status der ZIP-Kapsel (archived,in progress,waiting,not found)
  # find status within json
  status=`echo $statusline | grep -oe '\"status\"\:\"[^\"]*' | sed -e 's/\"//g' | cut -d":" -f2`
  #status=`echo $tempstatus | cut -d: -f2`
  # archivierte Version (1-master, 2-1.Delta.....)
  package=`echo $statusline|  grep -oe '\"packages\"\:\[\"[^\}]*' | grep -o ',' | wc -l`
  let package=package+1
  
  echo "Package Zauber: $status   $package  $fileversion"
  #echo "Status: $status

  # Test ob die betrachtete Datei im Protokoll steht und
  # wenn Status not found - also im Archiv noch nicht vorhanden - und die Masterdatei betrachtet wird -> Übertragung
  if [ -z "`grep $filename $PROTOC`" ]; then
     if [ "$status" = "not found" -a "$fileversion" = "1" ]; then
        echo "Starte Übertragung des SIPs in das DNS, Ersteinlieferung"
        rsync --progress -e ssh $file $INGESTUSER@$INGESTSERVER:$DSTDIR/$targetfilename
        FILELIST="$FILELIST\n $targetfilename"
        echo "Dateiübertragung erfolgt"
        echo "$filename"  >> $PROTOC
     fi
  fi

  # Wenn Masterkapsel bereits uebertragen wurde aber noch nicht bearbeitet 
  if [ -n "`grep $filename $PROTOC`" ]; then
     if [ "$status" = "not found" -a "$fileversion" = "1" ]; then
         echo "Lieferung wird abgebrochen, da sich Master noch in der Verarbeitung im DA NRW befindet"
         ProblemAnalyse
     fi 
  fi



  # Wenn Vorgaengerversion archiviert ist und die Archivierung der folgenden haengt
  if [ "$status" = "archived" -a "$package" != "$fileversion" ]; then
     echo "Lieferung wird abgebrochen, da die Verarbeitung des Vorgängerdeltas im DA NRW noch nicht abgeschlossen ist"
     ProblemAnalyse
  fi

  # betrachtete Datei ist archiviert und kann somit geloescht und aus dem Protokoll entfernt werden
  if [ "$status" = "archived" -a "$fileversion" = "$package" ]; then
     echo "Die Lieferung $file wurde erfolgreich im DA NRW archiviert und wird deshalb aus dem Protokoll gelöscht"
     # Datei löschen
     rm $file
     # Aus Protokoll loeschen
     (echo "g/${filename}/d"; echo 'wq') | ex -s $PROTOC
     (echo "g/${targetfilename}.*/d"; echo 'wq') | ex -s $WPROTOC
  fi
  # Vorgaengerversion ist archiviert und somit kann die neue Datei uebertragen werden wenn nicht lokal in Protokoll
  if [ -z "`grep $filename $PROTOC`" ]; then
    if [ "$status" = "archived" -a "$fileversion" = $((package +1)) ]; then
       echo "Starte Übertragung des SIPs in das DNS, Delta-Lieferung"
       rsync -e ssh $file $INGESTUSER@$INGESTSERVER:$DSTDIR/$targetfilename
       FILELIST="$FILELIST\n $targetfilename"
       echo "$filename"  >> $PROTOC
    fi
  fi
  if [ "$status" = "in progress" ]; then
     ProblemAnalyse
  fi 
  if [ "$status" = "in progress error" ]; then
     ProblemAnalyse
  fi
  if [ "$status" = "in progress waiting" ]; then
     ProblemAnalyse
  fi
  if [ "$status" = "in progress working" ]; then
     ProblemAnalyse
  fi
done

if [ -n "$FILELIST" ]; then
    	printf "Sehr geehrte Damen und Herren,\n\nnachfolgend aufgefuehrte Datei(n) wurde(n) in das Verzeichnis $DSTDIR uebertragen.\nWir bitten um Weiterleitung in das DA-NRW.\n$FILELIST\n\nMit freundlichen Gruessen" | mail -s "Betreff" name@mail.de
        touch $SRCDIR/fertig
	rsync -e ssh $SRCDIR/fertig $INGESTUSER@$INGESTSERVER:$DSTDIR/fertig
	rm -f $SRCDIR/fertig
fi

if [ -n "$PFILELIST" ]; then	
	printf "Sehr geehrte Damen und Herren\nnachfolgend aufgefuehrte Dateie(n) befinden sich seit mehreren Tagen in einem nicht archivierten Zustand. Die genaue Angabe ist der Uebersicht zu entnehmen, wobei der erste Wert die URN und der zweite Wert Anzahl der Tage darstellt, seit dem das entsprechende SIP uebertragen wurde.\n\nMit freundlichen Gruessen\n$PFILELIST" | mail -s "Betreff" name@mail.de
fi
