# Xiaomi Yi Camera control

async = require 'async'
events = require 'events'
net = require 'net'
stream = require 'stream'

shallowCopy = (obj) ->
  rv = {}
  for key of obj
    rv[key] = obj[key]
  return rv

Buffer.allocUnsafe ?= (size) -> new Buffer size

errorMessages =
  '0': 'Ok'
  '-3': 'Other device connected' # seems to happen when the iOS app is connected to the camera
  '-4': 'Unauthorized' # token invalid or not provided
  '-9': 'Invalid arguments'
  '-13': 'Invalid setting value'
  '-14': 'Setting already at requested value'
  '-15': 'Setting not writable'
  '-23': 'Invalid message id'
  '-26': 'File not found'

resolveErrorMessage = (code) -> errorMessages[String(code)] ? "Unknown code #{ code }"


class YiParser extends stream.Transform

  constructor: (options={}) ->
    options.objectMode = true
    @buffer = []
    super options

  _transform: (chunk, encoding, done) ->
    # the camera sends JSON encoded messages without any delimiters...
    messages = []
    @buffer.push chunk
    data = Buffer.concat @buffer
    @buffer = []

    # parse any full messages found
    while (idx = data.indexOf '}{') isnt -1
      try
        messages.push JSON.parse data.slice 0, idx + 1
      catch error
        console.log "WARNING: Got invalid JSON (#{ error.message })."
      data = data.slice idx + 1

    # try to parse potentially partial message
    if data.slice(-1).toString() is '}'
      try
        messages.push JSON.parse data
      catch error
        @buffer.push data
    else
      @buffer.push data

    # emit parsed messages on stream
    @push message for message in messages
    done()

class YiFile extends stream.Readable

  CHUNK_SIZE = Math.pow 2, 20

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
    autoconnect: true

  constructor: (@options={}) ->
    @options[key] ?= defaults[key] for key of defaults

    @token = null
    @cmdQueue = []
    @transferQueue = []

    @connect()
    @getToken()

  connect: ->
    @cmdSocket = new net.Socket
    @cmdSocket.connect
      port: @options.cmdPort
      host: @options.cameraHost

    @cmdParser = new YiParser
    @cmdParser.on 'data', @handleMsg.bind(this)
    @cmdSocket.pipe @cmdParser

    @cmdSocket.setTimeout 2000
    @cmdSocket.on 'timeout', => 
      # TODO: some sort of heartbeat to keep the timeout from triggering
      if @cmdSocket.readyState isnt 'open'
        @cmdSocket.destroy()

    @cmdSocket.on 'connect', =>
      @emit 'connected'
      do @runQueue

    @cmdSocket.on 'error', (error) ->
      console.log "WARNING: Socket error, #{ error.message }"

    @cmdSocket.on 'close', =>
      console.log "WARNING: Socket closed, trying to reconnect..."
      if cmd = @activeCmd
        @activeCmd = null
        clearTimeout cmd.timer
        cmd.callback new Error 'Socket closed'
      setTimeout (=> do @connect), 1000

  connectTransfer: ->
    @transferSocket = new net.Socket
    @transferSocket.on 'data', @handleTransfer.bind(this)
    @transferSocket.on 'connect', =>
      do @runTransfer
    @transferSocket.on 'error', (error) ->
      console.log "WARNING: Transfer socket error, #{ error.message }"
    @transferSocket.on 'close', ->
      console.log "WARNING: Transfer socket closed... reopening"
      setTimeout (=> do @connectTransfer), 1000
    @transferSocket.connect
      port: @options.transferPort
      host: @options.cameraHost

  getToken: ->
    @sendCmd {msg_id: 257, token: 0}, true, (error, result) =>
      if error?
        console.log "WARNING: Could not create token (#{ error.message })"
      else
        @token = result.param

  sendCmd: (data, highPriority, callback) ->
    unless data.msg_id?
      callback new Error 'Missing msg_id'
      return
    if arguments.length is 2
      callback = highPriority
      highPriority = false
    if highPriority
      @cmdQueue.unshift {data, callback}
    else
      @cmdQueue.push {data, callback}
    setImmediate => do @runQueue

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
        error = new Error resolveErrorMessage data.rval
        error.code = data.rval
        if error.code is -4
          @getToken()
      clearTimeout cmd.timer
      cmd.callback error, data
    else if data.msg_id is 7
      if data.type is 'get_file_complete'
        if @activeChunk?
          @activeChunk._md5 = data.param[1].md5sum
          do @finalizeChunk
        else
          console.log 'WARNING: Got get_file_complete event with no active chunk!'
      else
        @emit 'event', data
        @emit data.type, data.param
    else
      console.log 'WARNING: Got unknown message', data
    do @runQueue

  getFileChunk: (filename, offset, size, callback) ->
    @waitingChunks ?= []
    @waitingChunks.push {filename, offset, size, callback}
    do @runTransfer

  getFileInfo: (filename, callback) ->
    # NOTE: msg_id 1026 only actually works on media files, haven't found any command to get the size of other files, if there is any
    @sendCmd {msg_id: 1026, param: filename}, callback

  deleteFile: (filename, callback) ->
    @sendCmd {msg_id: 1281, param: filename}, callback

  listDirectory: (dirname, callback) ->
    @sendCmd {msg_id: 1282, param: "#{ dirname } -D -S"}, callback

  createReadStream: (filename) ->
    return new YiFile filename, this

  runTransfer: ->
    unless @transferSocket?
      do @connectTransfer
      return

    if @transferSocket.readyState isnt 'open' or @activeChunk? or @waitingChunks.length is 0
      return

    timeout = =>
      chunk = @activeChunk
      @activeChunk = null
      @transferSocket.destroy()
      @transferSocket = null
      chunk.callback new Error 'Timed out'

    chunk = @activeChunk = @waitingChunks.shift()
    chunk._pos = 0
    chunk._timer = setTimeout timeout, 30 * 1000

    @sendCmd {msg_id: 1285, param: chunk.filename, offset: chunk.offset, fetch_size: chunk.size}, (error, result) =>
      clearTimeout chunk._timer
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

  getSettings: (callback) ->
    @sendCmd {msg_id: 3}, (error, result) ->
      unless error?
        rv = []
        for item in result.param
          for key, value of item
            rv[key] = value
      callback error, rv

  writeSettings: (settings, callback) ->
    cmds = []
    for key, value of settings
      cmds.push
        msg_id: 2
        type: key
        param: value
    writeSetting = (cmd, callback) =>
      @sendCmd cmd, (error) ->
        # workaround for camera sending error code -14 if a setting is already at the requested value
        if error?.code is -14
          error = null
        callback error
    async.forEach cmds, writeSetting, callback

  getAvailableSettings: (callback) ->
    settings = undefined
    getSettings = (callback) => @getSettings (error, result) ->
      unless error?
        settings = result
      callback error

    getOption = (option, callback) =>
      @sendCmd {msg_id: 9, param: option}, callback

    getOptions = (callback) ->
      options = Object.keys settings
      async.map options, getOption, callback

    async.series [getSettings, getOptions], (error, result) ->
      unless error?
        rv = {}
        for item in result[1]
          key = item.param
          delete item['msg_id']
          delete item['rval']
          delete item['param']
          rv[key] = item
      callback error, rv

  triggerShutter: (callback) ->
    @sendCmd {msg_id: 769}, true, callback


module.exports = YiControl
