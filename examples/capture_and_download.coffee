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
  camera.triggerShutter callback

# listen to photo_taken events and download photos to current directory
camera.on 'photo_taken', (filename) ->
  console.log 'Photo taken! Downloading...'
  photo = camera.createReadStream filename
  localFile = fs.createWriteStream path.basename filename
  localFile.on 'close', ->
    console.log 'Photo saved! Removing from camera...'
    camera.deleteFile filename, (error) ->
      throw error if error?
      console.log 'Done!'
      camera.close()
  photo.pipe localFile

# run tasks
async.series tasks, (error) -> throw error if error?
