#!/bin/bash

# set current directory
cd /home/volumio/

# refresh packages
echo "Updating packages"
sudo apt-get update

## Install i2c-tools for i2c device scanning
sudo apt-get install -y i2c-tools

##############################
# install CAVA if not present
if [ ! -d "/home/volumio/cava" ]
then
  echo "Installing CAVA"
  sudo apt-get -y install git-core autoconf make libtool libfftw3-dev libasound2-dev
  git clone https://github.com/karlstav/cava
  cd cava
  sudo ./autogen.sh
  sudo ./configure
  sudo make
  sudo make install
  cd ..
else
  echo "CAVA already installed"
fi

##########################
# install mpd_oled
if [ ! -d "/home/volumio/mpd_oled" ]
then
  echo "Installing MPD_OLED"
  sudo apt -y install build-essential git-core autoconf make libtool libi2c-dev i2c-tools lm-sensors libcurl4-openssl-dev libmpdclient-dev libjsoncpp-dev
  git clone https://github.com/supercrab/mpd_oled
  cd mpd_oled
  if cat /etc/os-release | grep -q buster; then
    # buster build
    PLAYER=VOLUMIO LDLIBS="-li2c" make
  else
    # raspbian build
    PLAYER=VOLUMIO make
  fi
  # Copy file to bin folder for easy access
  cp mpd_oled /usr/local/bin/mpd_oled
else
  echo "MPD_OLED already installed"
fi


########################
# check i2c system buses 
echo "Checking I2C busses"
if ! grep -q "dtparam=i2c_arm=on" "/boot/config.txt"; then
  echo "* I2C-1 bus enabled"
else
  echo "* 12C-1 bus disabled"
fi
if ! grep -q "dtparam=i2c_vc=on" "/boot/config.txt"; then
  echo "* I2C-0 bus enabled"
else
  echo "* I2C-0 bus disabled"
fi

###############################################
# append I2C baudrate if it is not already set
if ! grep -q "i2c_arm_baudrate" "/boot/config.txt"; then
  if ! grep -q "i2c_arm_baudrate" "/boot/userconfig.txt"; then
    echo "Setting I2C baudrate"
    echo "dtparam=i2c_arm_baudrate=800000" >> /boot/userconfig.txt
  fi
fi

#############################################
# enable SPI if not enabled
if ! grep -q "spi=on" "/boot/config.txt"; then
  if ! grep -q "spi=on" "/boot/userconfig.txt"; then
    echo "Enabling SPI"
    echo "dtparam=spi=on" >> /boot/userconfig.txt
  fi
fi


# template file used to create /etc/mpd.conf
tmpl_file="/volumio/app/plugins/music_service/mpd/mpd.conf.tmpl"

# no need to continue if the file is already modified
if grep -q "/tmp/mpd_oled_fifo" "$tmpl_file"; then
  echo "mpd.conf template file aready includes a section for mpd_oled"
else
  #########################################
  # ensure mpd and mpd_oled are not running

  volumio stop

  # record if MPD is initially running as service, and stop if running
  if systemctl is-active --quiet mpd; then
    mpd_is_running="true"
    systemctl stop mpd
  fi

  # record if mpd_oled is initially running as service, and stop if running
  if systemctl is-active --quiet mpd_oled; then
    systemctl stop mpd_oled
  fi
  systemctl disable mpd_oled --quiet

  # Kill mpd_oled, mpd_oled_cava and cava, just to be sure, don't restart later
  killall --quiet cava
  killall --quiet mpd_oled_cava
  killall --quiet mpd_oled

  # Get rid of any stale FIFO
  rm -f /tmp/mpd_oled_fifo


  ######################
  # modify template file

  # audio_output section to add to the mpd.conf template file
  mpd_conf_txt="
  # add a FIFO to be read by a cava, which is run as a subprocess of mpd_oled
  audio_output {
          type            "\""fifo"\""
          name            "\""mpd_oled_FIFO"\""
          path            "\""/tmp/mpd_oled_fifo"\""
          format          "\""44100:16:2"\""
  }"

  # append the text to the template file
  echo "$mpd_conf_txt" >> "$tmpl_file"


  ##########################
  # regenerate /etc/mpd.conf

  # node script to call Volumio createMPDFile
  # https://community.volumio.org/t/command-to-regenerate-mpd-conf/44573
  mpd_conf_regen_js="const io = require('socket.io-client');
  const socket = io.connect('http://localhost:3000');
  const endPoint = { 'endpoint': 'music_service/mpd', 'method': 'createMPDFile', 'data': '' };
  socket.emit('callMethod', endPoint);
  setTimeout(() => process.exit(0), 1000);"

  # create a temporary directory
  tmp_dir=$(mktemp -d -t mpd_oled-XXXXXXXXXX)

  # create a file with the script text
  echo "$mpd_conf_regen_js" > "$tmp_dir/mpd_conf_regen.js"

  # make the Volume node modules accessible to the script
  ln -s /volumio/node_modules/ "$tmp_dir"

  # run the script
  node "$tmp_dir/mpd_conf_regen.js"

  # tidy up
  rm -rf "$tmp_dir"

fi

echo "Done"

#required to end the plugin install
echo "plugininstallend"
