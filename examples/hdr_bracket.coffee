###

  HDR Bracketing example using ambsh commands.

  For this to work you need to have an autoexec.ash file in the root of your sdcard containing this code:

  mkdir d:\commands
  while true; do
    if (mv d:\commands\lock d:\commands\locked) > d:\.null; then
      rm d:\commands\locked > d:\.null
      d:\commands\exec.ash > d:\.null
      rm d:\commands\exec.ash > d:\.null
    fi
    sleep 1
  done

###

async = require 'async'
fs = require 'fs'
path = require 'path'

YiChan = require './../src/'

tasks = []

camera = new YiChan
  cameraHost: 'localhost'

# 3 ev steps kinda, would be better to do it in manual mode (t ia2 -ae exp <iso> <shutter_idx> <gain_idx>) but then you need to know the initial values
photos = [
  {cmd: 't ia2 -adj l_expo 0', name: 'photo1.jpg'}
  {cmd: 't ia2 -adj l_expo 126', name: 'photo2.jpg'}
  {cmd: 't ia2 -adj l_expo 255', name: 'photo3.jpg'}
]

capturePhoto = (photo, callback) ->
  # run the command setting exposure level
  exec = (callback) ->
    camera.execCommand photo.cmd, callback
  # capture photo
  snap = (callback) ->
    camera.capturePhoto callback
  # run tasks and assign camera filename to photo object so we can download it later
  async.series [exec, snap], (error, results) ->
    unless error?
      photo.filename = results[1]
    callback error

downloadPhoto = (photo, callback) ->
  file = camera.createReadStream photo.filename
  file.on 'error', callback
  localFile = fs.createWriteStream photo.name
  localFile.on 'close', callback
  file.pipe localFile

removePhoto = (photo, callback) ->
  camera.deleteFile photo.filename, callback

# configure the camrea
tasks.push (callback) ->
  conf =
    capture_mode: 'precise quality'
    photo_size: '12M (4608x2592 16:9)'
    photo_quality: 'S.Fine'
  camera.writeSettings conf, callback

# capture the photos
tasks.push (callback) ->
  console.log 'Capturing photos...'
  async.forEachSeries photos, capturePhoto, callback

# download photos to current directory
tasks.push (callback) ->
  console.log 'Photos takens! Downloading...'
  async.forEachSeries photos, downloadPhoto, callback

# finally remove photos from camera
tasks.push (callback) ->
  console.log 'Photos saved! Removing from camera...'
  async.forEachSeries photos, removePhoto, callback

# run tasks
async.waterfall tasks, (error) ->
  throw error if error?
  camera.close()
