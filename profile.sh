# Country exit switch. Loaded for login shells and interactive ash.
if [ -f /etc/geo/current.sh ]; then
  . /etc/geo/current.sh
fi

geo() {
  /usr/local/bin/geo "$@"
  _geo_rc=$?
  if [ -f /etc/geo/current.sh ]; then
    . /etc/geo/current.sh
  else
    unset ALL_PROXY all_proxy http_proxy https_proxy HTTP_PROXY HTTPS_PROXY GEO_CODE
  fi
  return $_geo_rc
}
geous() { geo us; }
geoau() { geo au; }
geoca() { geo ca; }
geofr() { geo fr; }
geouk() { geo uk; }
geosg() { geo sg; }
geojp() { geo jp; }
geocn() { geo cn; }
geode() { geo de; }
geoph() { geo ph; }
geotr() { geo tr; }
geooff() { geo off; }
geostatus() { geo status; }
