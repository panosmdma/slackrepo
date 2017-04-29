#!/bin/bash
# Copyright 2014 David Spencer, Baildon, West Yorkshire, U.K.
# All rights reserved.  For licence details, see the file 'LICENCE'.
#-------------------------------------------------------------------------------
# dbfunctions.sh - database functions for slackrepo
#   db_init
#   db_error
#   db_set_buildsecs, db_get_buildsecs, db_del_buildsecs
#   db_set_pkgnam_itemid, db_get_pkgnam_itemid, db_get_itemid_pkgnams,
#     db_get_itemids, db_del_pkgnam, db_del_itemid_pkgnam
#   db_set_misc, db_get_misc, db_del_misc
#   db_set_rev, db_get_rev, db_get_dependers, db_del_rev
#   db_set_buildresults
#-------------------------------------------------------------------------------

function db_init
# Initialise the sqlite database
# Return status:
# 1 = any error, otherwise 0
{
  [ -n "$SR_DATABASE" ] || return 1

  latestschema='2.1'
  if [ -f "$SR_DATABASE" ]; then
    dbschema=$(db_get_misc schema 0 0) 2>/dev/null
  else
    log_normal "Creating database: $SR_DATABASE"
    dbschema=''
  fi

  case "$dbschema" in

  "$latestschema")
      # database schema is up to date :D
      : ;;

  '')
      # DATABASE SCHEMA NEEDS TO BE CREATED
      sqlite3 "$SR_DATABASE" << ++++
begin transaction;
create table if not exists buildresults ( itemid text primary key, time text, result text );
create table if not exists buildsecs ( itemid text primary key, secs text, mhzsum text, guessflag text );
create table if not exists packages ( pkgnam text primary key, itemid text );
create table if not exists misc ( key text primary key, value text );
create table if not exists revisions ( itemid text, dep text, deplist text, version text, built text, rev text, os text, hintcksum text, primary key (itemid,dep) );
commit;
++++
      dbstat=$?
      [ "$dbstat" != 0 ] && { db_error "$dbstat" ; return 1; }
      # load up the buildsecs table
      if [ -f /usr/share/slackrepo/"$OPT_REPO"/buildsecs_"$SYS_ARCH".sql ]; then
        log_normal "Populating the buildsecs table ... "
        sqlite3 "$SR_DATABASE" < /usr/share/slackrepo/"$OPT_REPO"/buildsecs_"$SYS_ARCH".sql
        dbstat=$?
        [ "$dbstat" != 0 ] && { db_error "$dbstat" ; return 1; }
        log_done
      fi
      # load up the misc table
      db_set_misc schema "$latestschema" || return 1
      # END DATABASE SCHEMA NEEDS TO BE CREATED
      ;;

  '0')
      # DATABASE SCHEMA NEEDS TO BE UPGRADED FROM v0
      log_normal "Upgrading the database schema from v${dbschema} to v${latestschema}."
      log_normal "If you have a lot of packages, this may take a few minutes."
      # (a) create the new tables
      sqlite3 "$SR_DATABASE" << ++++
begin transaction;
create table if not exists buildresults ( itemid text primary key, time text, result text );
create table if not exists buildsecs ( itemid text primary key, secs text, mhzsum text, guessflag text );
create table if not exists packages ( pkgnam text primary key, itemid text );
create table if not exists misc ( key text primary key, value text );
create table if not exists revisions ( itemid text, dep text, deplist text, version text, built text, rev text, os text, hintcksum text, primary key (itemid,dep) );
commit;
++++
      dbstat=$?
      [ "$dbstat" != 0 ] && { db_error "$dbstat" ; return 1; }
      # (b) upgrade the buildsecs table
      sqlite3 "$SR_DATABASE" "alter table buildsecs add column mhzsum text;"        1>/dev/null 2>/dev/null
      sqlite3 "$SR_DATABASE" "alter table buildsecs add column guessflag text;"     1>/dev/null 2>/dev/null
      sqlite3 "$SR_DATABASE" "update buildsecs set mhzsum='$SYS_MHz', guessflag='=';"
      dbstat=$?
      [ "$dbstat" != 0 ] && { db_error "$dbstat" ; return 1; }
      if [ -f /usr/share/slackrepo/"$OPT_REPO"/buildsecs_"$SYS_ARCH".sql ]; then
        log_normal "Populating the buildsecs table ... "
        sqlite3 "$SR_DATABASE" < /usr/share/slackrepo/"$OPT_REPO"/buildsecs_"$SYS_ARCH".sql
        dbstat=$?
        [ "$dbstat" != 0 ] && { db_error "$dbstat" ; return 1; }
        log_done
      fi
      # (c) populate the packages table from the package repo
      log_normal "Populating the packages table ... "
      ( cd "$SR_PKGREPO"
        echo "begin transaction;"
        find . -type f -name '*.t?z' -print | while read pkgpath; do
          pkgdir="${pkgpath%/*}"
          pkgbase="${pkgpath##*/}"
          pkgnam="${pkgbase%-*-*-*}"
          itemid="${pkgdir#./}"
          echo "insert into packages values ('$pkgnam','$itemid');"
        done
        echo "commit;"
      ) | sqlite3 "$SR_DATABASE" || return 1
      log_done
      # (d) populate the revisions table from the package repo
      log_normal "Populating the revisions table ... "
      MY_REVISIONS="$MYTMP"/revisions.sql
      echo "begin transaction;" >"$MY_REVISIONS"
      while read revfilepath; do
        itemid=$(dirname "${revfilepath#./}")
        itemprgnam="${itemid##*/}"
        while read revinfo; do
          # hopefully, this sets $prgnam, $version, $built, $buildrev, $slackware, $depends, $hintfile
          eval "$revinfo" 2>/dev/null
          if [ "$prgnam" = "$itemprgnam" ]; then
            dep='/'
          else
            # assume prgnam==pkgnam ;-)
            dep=$(db_get_pkgnam_itemid "$prgnam")
            [ -z "$dep" ] && continue
          fi
          deplist="${depends:-/}"
          echo "insert into revisions values('$itemid','$dep','${deplist//:/,}','${version:-/}','${built:-0}','${buildrev:-0}','slackware${slackware}','${hintfile:-/}');" >>"$MY_REVISIONS"
          unset prgnam version built buildrev slackware depends hintfile
        done <"$SR_PKGREPO"/"$revfilepath"
        rm -f "$SR_PKGREPO"/"$revfilepath"
      done < <(cd "$SR_PKGREPO"; find . -type f -name '*.rev' -o -name '.revision')
      echo "commit;" >>"$MY_REVISIONS"
      sqlite3 "$SR_DATABASE" < "$MY_REVISIONS" || return 1
      rm -f "$MY_REVISIONS"
      log_done
      # (e) convert the backup repo's revision data
      log_normal "Converting backup revision data ... "
      while read revfilepath; do
        itemid=$(dirname "${revfilepath#./}")
        itemprgnam="${itemid##*/}"
        newrevfilepath="$SR_PKGBACKUP"/"$itemid"/revision
        > "$newrevfilepath"
        while read revinfo; do
          eval "$revinfo" 2>/dev/null
          # sets $prgnam, $version, $built, $buildrev, $slackware, $depends, $hintfile
          if [ "$prgnam" = "$itemprgnam" ]; then
            dep='/'
          else
            dep=$(db_get_pkgnam_itemid "$prgnam")
            [ -z "$dep" ] && continue
          fi
          deplist=$(echo "${depends:-/}" | tr ':' ',')
          os="slackware${slackware}"
          hintcksum="${hintfile:-/}"
          echo "$itemid $dep $deplist $version $built $buildrev $os $hintcksum" >> "$newrevfilepath"
          unset prgnam version built buildrev slackware depends hintfile
        done <"$SR_PKGBACKUP"/"$revfilepath"
        rm -f "$SR_PKGBACKUP"/"$revfilepath"
      done < <(cd "$SR_PKGBACKUP"; find . -type f -name '*.rev' -o -name '.revision')
      log_done
      db_set_misc schema "$latestschema" || return 1
      # END UPGRADE DATABASE SCHEMA FROM v0
      ;;

  '1' | '2')
      # DATABASE SCHEMA NEEDS TO BE UPGRADED FROM v1 OR v2
      log_normal "Upgrading the database schema from v${dbschema} to v${latestschema}."
      sqlite3 "$SR_DATABASE" << ++++
begin transaction;
create table if not exists buildresults ( itemid text primary key, time text, result text );
alter table buildsecs rename to oldbuildsecs;
create table buildsecs as select itemid, secs, bogomips/2.0 as mhzsum, guessflag from oldbuildsecs;
drop table oldbuildsecs;
commit;
++++
      dbstat=$?
      [ "$dbstat" != 0 ] && { db_error "$dbstat" ; return 1; }
      db_set_misc schema "$latestschema" || return 1
      # END UPGRADE DATABASE SCHEMA FROM v1 OR v2
      ;;

  esac

  return 0
}

#-------------------------------------------------------------------------------

function db_error
# Error handling for the database.  (probably a bit too obsessive)
# $1 = sqlite status code
# Return status: always 0
{
  local warntext="Internal error in ${FUNCNAME[1]}"
  case "$1" in
  1)   log_warning -n "${warntext}: SQL error or missing database" ;;
  2)   log_warning -n "${warntext}: Internal logic error in SQLite" ;;
  3)   log_warning -n "${warntext}: Access permission denied" ;;
  4)   log_warning -n "${warntext}: Callback routine requested an abort" ;;
  5)   log_warning -n "${warntext}: The database file is locked"; sleep 1 ;;
  6)   log_warning -n "${warntext}: A table in the database is locked" ;;
  7)   log_warning -n "${warntext}: A malloc() failed" ;;
  8)   log_warning -n "${warntext}: Attempt to write a readonly database" ;;
  9)   log_warning -n "${warntext}: Operation terminated by sqlite3_interrupt()" ;;
  10)  log_warning -n "${warntext}: Some kind of disk I/O error occurred" ;;
  11)  log_warning -n "${warntext}: The database disk image is malformed" ;;
  12)  log_warning -n "${warntext}: Unknown opcode in sqlite3_file_control()" ;;
  13)  log_warning -n "${warntext}: Insertion failed because database is full" ;;
  14)  log_warning -n "${warntext}: Unable to open the database file" ;;
  15)  log_warning -n "${warntext}: Database lock protocol error" ;;
  16)  log_warning -n "${warntext}: Database is empty" ;;
  17)  log_warning -n "${warntext}: The database schema changed" ;;
  18)  log_warning -n "${warntext}: String or BLOB exceeds size limit" ;;
  19)  log_warning -n "${warntext}: Abort due to constraint violation" ;;
  20)  log_warning -n "${warntext}: Data type mismatch" ;;
  21)  log_warning -n "${warntext}: Library used incorrectly" ;;
  22)  log_warning -n "${warntext}: Uses OS features not supported on host" ;;
  23)  log_warning -n "${warntext}: Authorization denied" ;;
  24)  log_warning -n "${warntext}: Auxiliary database format error" ;;
  25)  log_warning -n "${warntext}: 2nd parameter to sqlite3_bind out of range" ;;
  26)  log_warning -n "${warntext}: File opened that is not a database file" ;;
  27)  log_warning -n "${warntext}: Notifications from sqlite3_log()" ;;
  28)  log_warning -n "${warntext}: Warnings from sqlite3_log()" ;;
  100) log_warning -n "${warntext}: sqlite3_step() has another row ready" ;;
  101) log_warning -n "${warntext}: sqlite3_step() has finished executing" ;;
  '')  log_warning -n "${warntext}: sqlite3 status is null" ;;
  *)   log_warning -n "${warntext}: sqlite3 status $1" ;;
  esac
  return 0
}

#-------------------------------------------------------------------------------
# Set, get or delete a record in the 'buildsecs' table.
#   itemid text primary key
#   secs text          (the number of seconds to build the item)
#   mhzsum text        (the sum of MHz of the box that built it - MHz*nproc if all cpus are the same)
#   guessflag text
#     '~' means this record is a slackrepo-provided guess
#     '=' means this record is not a guess, we have actually built it on this box
#-------------------------------------------------------------------------------

function db_set_buildsecs
# Record a build time
# $1 = itemid
# $2 = elapsed seconds
# (mhzsum is always set to $SYS_MHz, and guessflag is always set to '=')
{
  [ -z "$1" -o -z "$2" ] && return 1
  [ -z "$SYS_MHz" ] && return 0
  sqlite3 "$SR_DATABASE" \
    "insert or replace into buildsecs ( itemid, secs, mhzsum, guessflag ) values ( '$1', '$2', $SYS_MHz, '=' );"
  dbstat=$?
  [ "$dbstat" != 0 ] && { db_error "$dbstat" ; return 1; }
  return 0
}

function db_get_buildsecs
# Retrieve a build time (if no database, do not print anything)
# $1 = itemid
# Prints "secs mhzsum guessflag" on standard output
# (prints nothing if itemid is not in the table)
{
  [ -z "$1" ] && return 1
  sqlite3 "$SR_DATABASE" \
    "select secs, mhzsum, guessflag from buildsecs where itemid='$1';" | tr '|' ' '
  dbstat="${PIPESTATUS[0]}"
  [ "$dbstat" != 0 ] && { db_error "$dbstat" ; return 1; }
  return 0
}

function db_del_buildsecs
# Delete a build time
# $1 = itemid
{
  [ -z "$1" ] && return 1
  sqlite3 "$SR_DATABASE" \
    "delete from buildsecs where itemid='$1';"
  dbstat=$?
  [ "$dbstat" != 0 ] && { db_error "$dbstat" ; return 1; }
  return 0
}

#-------------------------------------------------------------------------------
# Set, get or delete a record in the 'packages' table.
# The 'packages' table maps package names back to the itemid that build them.
#   pkgnam text primary key
#   itemid text
#-------------------------------------------------------------------------------

function db_set_pkgnam_itemid
# Record a package name and its corresponding itemid.
# $1 = pkgnam
# $2 = itemid
{
  [ -z "$1" -o -z "$2" ] && return 1
  sqlite3 "$SR_DATABASE" \
    "insert or replace into packages ( pkgnam, itemid ) values ( '$1', '$2' );"
  dbstat=$?
  [ "$dbstat" != 0 ] && { db_error "$dbstat" ; return 1; }
  return 0
}

function db_get_pkgnam_itemid
# Print the itemid for a given pkgnam on standard output.
# $1 = pkgnam
{
  [ -z "$1" ] && return 1
  sqlite3 "$SR_DATABASE" \
    "select itemid from packages where pkgnam='$1';"
  dbstat=$?
  [ "$dbstat" != 0 ] && { db_error "$dbstat" ; return 1; }
  return 0
}

function db_get_itemids
# List the itemids matching a given glob on standard output.
# The itemids must have existing packages.
# $1 = glob
{
  [ -z "$1" ] && return 1
  sqlite3 "$SR_DATABASE" \
    "select distinct itemid from packages where '/'||itemid||'/' glob '*/$1/*' order by itemid asc;"
  dbstat=$?
  [ "$dbstat" != 0 ] && { db_error "$dbstat" ; return 1; }
  return 0
}

function db_get_itemid_pkgnams
# Print the pkgnams for a given itemid on standard output.
# $1 = itemid
{
  [ -z "$1" ] && return 1
  sqlite3 "$SR_DATABASE" \
    "select pkgnam from packages where itemid='$1';"
  dbstat=$?
  [ "$dbstat" != 0 ] && { db_error "$dbstat" ; return 1; }
  return 0
}

function db_del_pkgnam
# Delete all records for a specified pkgnam.
# $1 = pkgnam
{
  [ -z "$1" ] && return 1
  sqlite3 "$SR_DATABASE" \
    "delete from packages where pkgnam='$1';"
  dbstat=$?
  [ "$dbstat" != 0 ] && { db_error "$dbstat" ; return 1; }
  return 0
}

function db_del_itemid_pkgnam
# Delete all records for a specified itemid.
# $1 = itemid
{
  [ -z "$1" ] && return 1
  sqlite3 "$SR_DATABASE" \
    "delete from packages where itemid='$1';"
  dbstat=$?
  [ "$dbstat" != 0 ] && { db_error "$dbstat" ; return 1; }
  return 0
}

#-------------------------------------------------------------------------------
# Set, get or delete a record in the 'misc' table.
# The 'misc' table stores key/value pairs:
#   schema      (version number of the database schema)
#-------------------------------------------------------------------------------

function db_set_misc
# Record a misc key/value pair
# $1 = key
# $2 = value (optional, default null)
{
  [ -z "$1" ] && return 1
  sqlite3 "$SR_DATABASE" \
    "insert or replace into misc ( key, value ) values ( '$1', '$2' );"
  dbstat=$?
  [ "$dbstat" != 0 ] && { db_error "$dbstat" ; return 1; }
  return 0
}

function db_get_misc
# Get the value for a given key
# $1 = key
# $2 = default if not found (optional)
# $3 = default if error (optional -- error is suppressed)
{
  [ -z "$1" ] && return 1
  local value dbstat
  value=$(sqlite3 "$SR_DATABASE" "select value from misc where key='$1';" 2>/dev/null)
  dbstat=$?
  if [ "$dbstat" = 0 ]; then
    echo "${value:-$2}"
    return 0
  else
    if [ -n "$3" ]; then
      echo "$3"
      return 0
    else
      db_error "$dbstat"
      return 1
    fi
  fi
}

function db_del_misc
# Delete a misc key/value pair
# $1 = key
{
  [ -z "$1" ] && return 1
  sqlite3 "$SR_DATABASE" \
    "delete from misc where key='$1';"
  dbstat=$?
  [ "$dbstat" != 0 ] && { db_error "$dbstat" ; return 1; }
  return 0
}

#-------------------------------------------------------------------------------
# Set, get or delete records in the 'revisions' table.
#
# The 'revisions' table contains historical revision info about existing
# packages in the Package Repository.
#
# Note that if an item has dependencies, there will be multiple records in the table.
# The main record for 'itemid' has '/' in the dep column, and a comma separated list
# of dependencies in the deplist column ('/' if it has no deps).
# There will also be a subsidiary record for each dep, with 'itemid' in the itemid column,
# 'dep' in the dep column, and '/' in the deplist column.
# The table's primary key is composite on the itemid and dep columns.
#
# Fields are as follows, note that / is used as a placeholder for empty fields.
#   itemid text     (the item's itemid)
#   dep text        (the dependency's itemid, or / if this is the item's main record)
#   deplist text    (comma separated list of itemid's dependencies, or /)
#   version text    (item's or dep's version when it was built)
#   built text      (secs since epoch when item or dep was built)
#   rev text        (item's or dep's gitrevision when it was built, secs since epoch if not git)
#   os text         (<osname><osversion> when item or dep was built)
#   hintcksum text  (item's or dep's hintfile md5sum when it was built, / if no hintfile)
#
# See also the 'print_current_revinfo' function.
#
# This bash array caches "main" records in the 'revisions' table (indexed by itemid).
declare -A REVCACHE
#-------------------------------------------------------------------------------

function db_set_rev
# Record a revision
# $1 = itemid
# $2 = dep
# $3...$8 = deplist, version, built, rev, os, hintcksum
# (all eight arguments must be specified, although only the first two are checked)
{
  [ -z "$1" -o -z "$2" ] && return 1
  local itemid="$1"
  local dep="${2:-/}"
  [ "$dep" = '/' ] && REVCACHE[$itemid]="$3 $4 $5 $6 $7 $8"
  sqlite3 "$SR_DATABASE" \
    "insert or replace into revisions (itemid,dep,deplist,version,built,rev,os,hintcksum) values ('$itemid','$dep','$3','$4','$5','$6','$7','$8');"
  dbstat=$?
  [ "$dbstat" != 0 ] && { db_error "$dbstat" ; return 1; }
  return 0
}

function db_get_rev
# Get revision data for an item
# Prints "deplist version built rev os hintcksum" to standard output
#   (or prints nothing if not in database)
# $1 = itemid
# $2 = dep, default '/'
{
  [ -z "$1" ] && return 1
  local itemid="$1"
  local dep="${2:-/}"
  if [ "$dep" = '/' ] && [ "${REVCACHE[$itemid]+yesitisset}" = 'yesitisset' ]; then
    echo "${REVCACHE[$itemid]}"
    return 0
  else
    local dbinfo=$(sqlite3 "$SR_DATABASE" \
      "select deplist,version,built,rev,os,hintcksum from revisions where itemid='$1' and dep='$dep';" | tr '|' ' ')
    dbstat="${PIPESTATUS[0]}"
    [ "$dbstat" != 0 ] && { db_error "$dbstat" ; return 1; }
    [ "$dep" = '/' ] && REVCACHE[$itemid]="$dbinfo"
    echo "$dbinfo"
    return 0
  fi
}

function db_get_dependers
# Print a list of itemids where the packages currently depend on the given item
# $1 = itemid of dependee
{
  [ -z "$1" ] && return 1
  local itemid="$1"
  sqlite3 "$SR_DATABASE" \
    "select itemid from revisions where dep='$itemid';"   # sql ftw :D
  dbstat=$?
  [ "$dbstat" != 0 ] && { db_error "$dbstat" ; return 1; }
  return 0
}

function db_del_rev
# Delete all revision records for an item
# $1 = itemid
{
  [ -z "$1" ] && return 1
  unset REVCACHE[$itemid]
  sqlite3 "$SR_DATABASE" \
    "delete from revisions where itemid='$1';"
  dbstat=$?
  [ "$dbstat" != 0 ] && { db_error "$dbstat" ; return 1; }
  return 0
}

#-------------------------------------------------------------------------------
# Set a record in the 'buildresults' table.
# This table is effectively write-only (it is used for creating reports),
# so there are no 'get' and 'del' functions.
#-------------------------------------------------------------------------------

function db_set_buildresults
# Record the outcome of a build
# $1 = itemid
# $2 = result (ok, skipped, unsupported, failed, or aborted)
{
  [ -z "$1" ] && return 1
  [ -z "$2" ] && return 1
  sqlite3 "$SR_DATABASE" \
    "insert or replace into buildresults ( itemid, time, result ) values ( '$1', $(date +%s), '$2' );"
  dbstat=$?
  [ "$dbstat" != 0 ] && { db_error "$dbstat" ; return 1; }
  return 0
}

#-------------------------------------------------------------------------------
# Set or get records in the 'slackbuilds' table.
# This is just a list of SlackBuilds in the repo. We use the sqlite db because
# (1) updatedb/slocate is grotesquely slow and catalogues everything,
# (2) find is too slow to use every time we need a lookup, and
# (3) we can't use a flat file because we need to match shell globs, and grep doesn't grok globs.
#-------------------------------------------------------------------------------

function db_index_slackbuilds
# List all the SlackBuild pathnames, load them into the db. Any existing table is dropped.
# Paradoxically, the database table is not indexed :-)
# No parameters.
{
  MY_SBLIST="$MYTMP"/sblist
  ( cd "$SR_SBREPO"; find . -name '.git' -prune -o -type f -name '*.SlackBuild' -print | sed 's/^\.\///' > "$MY_SBLIST" )
  echo -e \
    "drop table if exists slackbuilds; create table slackbuilds(relpath text);\n.mode csv\n.import $MY_SBLIST slackbuilds" \
    | sqlite3 "$SR_DATABASE"
  dbstat=$?
  rm "$MY_SBLIST"
  [ "$dbstat" != 0 ] && { db_error "$dbstat" ; return 1; }
  return 0
}

function db_get_slackbuilds
# Print a list of SlackBuild pathnames that match a glob.
# $1 = the glob to match
{
  [ -z "$1" ] && return 1
  sqlite3 "$SR_DATABASE" \
    "select relpath from slackbuilds where '/'||relpath||'/' glob '*/$1/*' order by relpath asc;"
  dbstat=$?
  [ "$dbstat" != 0 ] && { db_error "$dbstat" ; return 1; }
  return 0
}
