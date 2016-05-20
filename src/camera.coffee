net = require 'net'
es = require 'event-stream'

# Xiaomi Yi Camera control

stream = require 'stream'
crypto = require 'crypto'

shallowCopy = (obj) ->
  rv = {}
  for key of obj
    rv[key] = obj[key] 
  return rv


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







class YiControl

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
    console.log 'send', msg
    @cmdSocket.write msg

  handleMsg: (data) ->
    if @activeCmd?.data.msg_id is data.msg_id
      cmd = @activeCmd
      @activeCmd = null
      console.log 'got response!', data
      if data.rval isnt 0
        error = new Error "Unexpected rval: #{ data.rval }"

      clearTimeout cmd.timer
      cmd.callback error, data
    else if data.msg_id is 7
      console.log 'event', data.type, data.param
      if data.type is 'get_file_complete'
        if @activeChunk?
          @activeChunk._md5 = data.param[1].md5sum
          do @finalizeChunk
        else
          console.log 'WARNING: Got get_file_complete event with no active chunk!'
    else
      console.log 'got unknown message', data
    do @runQueue

  getFileChunk: (filename, offset, size, callback) ->
    @waitingChunks ?= []
    @waitingChunks.push {filename, offset, size, callback}
    do @runTransfer

  getFileInfo: (filename, callback) -> 
    @sendCmd {msg_id: 1026, param: filename}, callback

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
      chunk.buffer ?= Buffer.alloc chunk.size
      chunk._pos += data.copy chunk.buffer, chunk._pos

    if chunk._pos >= chunk.size
      chunk._readComplete = true
      do @finalizeChunk




  # sendCmd: (data) ->
  #   msg = JSON.stringify data
  #   @cmdSocket.write msg

  # handleCmd: (cmd) ->
  #   if cmd.rval? and cmd.rval isnt 0
  #     console.log "got error", cmd
  #     return

  #   switch cmd.msg_id
  #     when 257
  #       # got token
  #       @token = cmd.param
  #       console.log 'token set', @token
  #       @sendCmd {msg_id:1282, param:'-D -S', token: @token}
  #     else
  #       console.log 'unhandled command', cmd


# command queue
# push command
# message handler



# read request file, size, offset

yt = new YiControl

SP = require 'streamspeed'

s = new SP


ts1 = yt.createReadStream '/tmp/fuse_d/DCIM/100MEDIA/YDXJ0001.jpg'

s.add ts1
s.on 'speed', (speed, avg) ->
  console.log SP.toHuman(speed, 's'), SP.toHuman(avg, 's')

#ts2 = yt.createReadStream '/tmp/fuse_d/DCIM/100MEDIA/YDXJ0001.jpg'

fs = require 'fs'

ts1.pipe fs.createWriteStream('t1.jpg')






#ts2.pipe fs.createWriteStream('t2.jpg')

# ts.on 'data', (data) ->
#   console.log 'stream got', data.length


# yt.sendCmd {msg_id: 769}, (error, result) ->
#   console.log error, result
#   # yt.sendCmd {msg_id: 1282, param: '-D -S'}, (error, result) ->
#   #   console.log error, result

# {"msg_id":1285,"param":"%s","offset":%d,"fetch_size":%d}'
# yt.sendCmd {msg_id: 1285, param: '/tmp/fuse_d/DCIM/100MEDIA/YDXJ0001.jpg', offset: 0, fetch_size: 500}, (error, result) ->
#   console.log error, result

# yt.sendCmd {msg_id: 1285, param: '/tmp/fuse_d/DCIM/100MEDIA/YDXJ0001.jpg', offset: 0, fetch_size: 500}, (error, result) ->
#   console.log error, result

# yt.sendCmd {msg_id: 1026, param: '/tmp/fuse_d/DCIM/100MEDIA/YDXJ0001.jpg'}, (error, result) ->
#   console.log error, result

# yt.getFileChunk '/tmp/fuse_d/DCIM/100MEDIA/YDXJ0001.jpg', 0, 5000, (error, result) ->
#   console.log error, result

#yt.getFileChunk '/tmp/fuse_d/DCIM/100MEDIA/YDXJ0001.jpg', 2752758 - 4000, 5000, (error, result) ->
#  console.log '2', error, result


  # yt.sendCmd {msg_id: 1282, param: '-D -S'}, (error, result) ->
  #   console.log error, result


# yt.sendCmd {msg_id: 1283, param: '/etc'}, (error, result) ->
#   console.log error, result
#   yt.sendCmd {msg_id: 1282, param: '-D -S'}, (error, result) ->
#     console.log error, result

# s1.pipe parser

# parser.on 'data', ->
#   console.log 'esdata', arguments

# s1.on 'data', (data) ->
#   console.log "got '#{ data.toString() }'"

# #   unless opa
# #     opa = true
# #     setTimeout ->
# #       s1.write '{"msg_id":3, "token":8}\n'
# #     , 1000
# #     


# API_PORT=7878
# TRANSFER_PORT=8787
# CAMERA_IP='192.168.42.1'


# console.log net.Socket

# s1 = new net.Socket

# s1.connect
#   port: API_PORT
#   host: CAMERA_IP


# s1.on 'connect', ->
#   console.log 'connected?', arguments
#   s1.write '{"msg_id":257,"token":0}\n'

# opa = false
