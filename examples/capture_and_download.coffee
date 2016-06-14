async = require 'async'
fs = require 'fs'
path = require 'path'

YiChan = require './../src/'

tasks = []
camera = new YiChan

# configure the camrea
tasks.push (callback) ->
  conf =
    capture_mode: 'precise quality'
    photo_size: '12M (4608x2592 16:9)'
    photo_quality: 'S.Fine'
  camera.writeSettings conf, callback

# trigger capture
tasks.push (callback) ->
  console.log 'Capturing photo...'
  camera.capturePhoto callback

# download photo to current directory
tasks.push (filename, callback) ->
  console.log 'Photo taken! Downloading...'
  photo = camera.createReadStream filename
  localFile = fs.createWriteStream path.basename filename
  localFile.on 'close', ->
    console.log 'Photo saved! Removing from camera...'
    camera.deleteFile filename, (error) ->
      unless error?
        console.log 'Done!'
        camera.close()
      callback error
  photo.pipe localFile

# run tasks
async.waterfall tasks, (error) -> throw error if error?
