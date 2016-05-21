# Xiaomi Yi Camera control

events = require 'events'
net = require 'net'
stream = require 'stream'

shallowCopy = (obj) ->
  rv = {}
  for key of obj
    rv[key] = obj[key]
  return rv

Buffer.allocUnsafe ?= (size) -> new Buffer size

class YiParser extends stream.Transform

  constructor: (options={}) ->
    options.objectMode = true
    super options

  _transform: (chunk, encoding, done) ->
    try
      payload = JSON.parse chunk
    catch error
      console.log 'failed to parse', chunk.toString(), error.message
    @push payload
    done()

class YiFile extends stream.Readable

  CHUNK_SIZE = 2e5

  constructor: (@filename, @control) ->
    @offset = 0
    @control.getFileInfo @filename, (error, result) =>
      if error?
        @emit 'error', error
      else
        @size = result.size
        @read 0
    super()

  _read: ->
    unless @size?
      @push()
      return
    if @offset >= @size
      @push null
      return
    chunkSize = Math.min @size - @offset, CHUNK_SIZE
    @control.getFileChunk @filename, @offset, chunkSize, (error, chunk) =>
      if error?
        @emit 'error', error
      else
        @offset += chunkSize
        @push chunk

class YiControl extends events.EventEmitter

  defaults =
    cameraHost: '192.168.42.1'
    cmdPort: 7878
    transferPort: 8787
    cmdTimeout: 5000 # ms

  constructor: (@options={}) ->
    @options[key] ?= defaults[key] for key of defaults

    @token = null
    @cmdQueue = []
    @transferQueue = []

    @cmdSocket = new net.Socket
    @cmdSocket.connect
      port: @options.cmdPort
      host: @options.cameraHost

    @transferSocket = new net.Socket
    @transferSocket.on 'data', @handleTransfer.bind(this)
    @transferSocket.connect
      port: @options.transferPort
      host: @options.cameraHost

    @cmdParser = new YiParser
    @cmdParser.on 'data', @handleMsg.bind(this)
    @cmdSocket.pipe @cmdParser

    @cmdSocket.on 'connect', =>
      do @runQueue

    @sendCmd {msg_id: 257, token: 0}, (error, result) =>
      if error?
        console.log "Error creating token: #{ error.message }"
      else
         @token = result.param

  sendCmd: (data, callback) ->
    unless data.msg_id?
      callback new Error 'Missing msg_id'
      return
    @cmdQueue.push {data, callback}
    do @runQueue

  runQueue: ->
    if @cmdSocket.readyState isnt 'open' or @activeCmd? or @cmdQueue.length is 0
      return

    timeout = =>
      @activeCmd = null
      cmd.callback new Error 'Timed out'

    @activeCmd = cmd = @cmdQueue.shift()
    cmd.timer = setTimeout timeout, @options.cmdTimeout

    data = shallowCopy cmd.data
    if @token? and data.msg_id isnt 257
      data.token = @token

    msg = JSON.stringify data
    @cmdSocket.write msg

  handleMsg: (data) ->
    if @activeCmd?.data.msg_id is data.msg_id
      cmd = @activeCmd
      @activeCmd = null
      if data.rval isnt 0
        error = new Error "Unexpected rval: #{ data.rval }"
      clearTimeout cmd.timer
      cmd.callback error, data
    else if data.msg_id is 7
      if data.type is 'get_file_complete'
        if @activeChunk?
          @activeChunk._md5 = data.param[1].md5sum
          do @finalizeChunk
        else
          console.log 'WARNING: Got get_file_complete event with no active chunk!'
        @emit 'event', data
    else
      console.log 'WARNING: Got unknown message', data
    do @runQueue

  getFileChunk: (filename, offset, size, callback) ->
    @waitingChunks ?= []
    @waitingChunks.push {filename, offset, size, callback}
    do @runTransfer

  getFileInfo: (filename, callback) ->
    @sendCmd {msg_id: 1026, param: filename}, callback

  listDirectory: (path, callback) ->

  createReadStream: (filename) ->
    stream = new YiFile filename, this

  runTransfer: ->
    if @activeChunk? or @waitingChunks.length is 0
      return

    chunk = @activeChunk = @waitingChunks.shift()
    chunk._pos = 0

    @sendCmd {msg_id: 1285, param: chunk.filename, offset: chunk.offset, fetch_size: chunk.size}, (error, result) =>
      if error?
        chunk.callback error
        @activeChunk = null
      else
        chunk.size = result.rem_size

  finalizeChunk: ->
    unless chunk = @activeChunk
      return
    if chunk._readComplete and chunk._md5?
      # the checksum only matches what is sent if the whole file is asked for with fetch_size
      # i guess they have some bug with calculating it for partial requests
      # checksum = crypto
      #   .createHash 'md5'
      #   .update chunk.buffer
      #   .digest 'hex'
      chunk.callback null, chunk.buffer
      @activeChunk = null
      do @runTransfer

  handleTransfer: (data) ->
    unless chunk = @activeChunk
      console.log 'WARNING: Got transfer data without active chunk!', data.length
      return

    if data.length is chunk.size
      chunk.buffer = data
      chunk._pos = data.length
    else
      chunk.buffer ?= Buffer.allocUnsafe chunk.size
      chunk._pos += data.copy chunk.buffer, chunk._pos

    if chunk._pos >= chunk.size
      chunk._readComplete = true
      do @finalizeChunk


yt = new YiControl
  cameraHost: '192.168.1.32'

###

  Messages IDs

  1  - ? error -9
  2  - ? error -9
  3  - get settings, optional param setting name
  4  - single beep? start recording?
  5  - error -9
  6  - error -9
  7  - error -23
  8  - error -13
  9  - rval 0
  10 - rval 0
  11 - hwinfo
  12 - error -23
  13 - battery level
  14 - error -9
  15 - error -9
  16 - error -14
  17 - error -23
  18 - error -23
  18

  1536 disconnect wifi clients?


  Error codes

  0  ok
  -9 invalid arguments?
  -23 message id does not exist?
  -14 no idea
  -13 no idea

###

###
{ rval: 0, msg_id: 11,
  brand: 'Ambarella',
  model: 'Default',
  api_ver: '2.8.00',
  fw_ver: 'Sun Sep  6 14:42:43 HKT 2015',
  app_type: 'sport',
  logo: '/tmp/fuse_z/app_logo.jpg',
  chip: 'a7l',
  http: 'disable' }
###



# async = require 'async'

# testCommand = (id, callback) ->
#   yt.sendCmd {msg_id: id}, (error, result) ->
#     console.log id, result
#     callback null, "#{ id } - #{ JSON.stringify result }"

# async.mapSeries [1500 ... 3000], testCommand, (error, result) ->
#   console.log result.join '\n'

yt.sendCmd {msg_id: 13}, (error, result) ->
  console.log error, result
