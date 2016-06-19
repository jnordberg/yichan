# Xiaomi Yi Camera control

async = require 'async'
events = require 'events'
net = require 'net'
stream = require 'stream'
crypto = require 'crypto'

AMBA_GET_SETTING                =  1 # type = setting name
                                     # app_status
AMBA_SET_SETTINGS               =  2 # type = name, param = value
                                     # restore_factory_settings, param: on
                                     # buzzer_ring param: on/off
                                     # dev_reboot param: on
AMBA_GET_ALL_CURRENT_SETTINGS   =  3
AMBA_FORMAT_DRIVE               =  4 # param can be disk drive letter, e.g. 'D:'
AMBA_GET_SPACE                  =  5 # type: total/free
# UNKNOWN                       =  6 # rval: -13, {'type':'%s','param':'%s','param_size':%d}
# NOT USED                      =  7
# UNKNOWN                       =  8 # rval: -13
AMBA_GET_SINGLE_SETTING_OPTIONS =  9 # param = name
# UNKNOWN                       = 10 # rval: 0
AMBA_GET_SYSTEM_INFO            = 11 # json object with firmware versions
# NOT USED                      = 12
AMBA_GET_BATTERY_INFO           = 13 # battery level and source
# UNKNOWN                       = 14 # rval -1 if param and type set
# UNKNOWN                       = 15 # rval -24 if type set
# UNKNOWN                       = 16 # rval 0 or -14

AMBA_CREATE_TOKEN   = 0x101
AMBA_RELEASE_TOKEN  = 0x102
AMBA_START_PREVIEW  = 0x103
AMBA_STOP_VF   = 0x104

AMBA_RECORD_VIDEO        = 0x201 # start video recording
AMBA_STOP_VIDEO_RECORD   = 0x202 # stop recording, errors if not recording
AMBA_GET_RECORDED_LENGTH = 0x203 # returns number of seconds recording lapsed
# UNKNOWN                = 0x204 # ? rval 0 if recording error otherwise

AMBA_TAKE_PHOTO   = 0x301 # take photo
AMBA_STOP_CAPTURE = 0x302 # stop capture

AMBA_GET_THUMB      = 0x401 # param: filename, type: any string?
                            # > {"msg_id": 1025, "param": "/tmp/fuse_d/DCIM/129MEDIA/YDXJ2007.jpg", "type": "foo"}
                            # < { rval: 0, msg_id: 1025, size: 1673, type: 'thumb', md5sum: '5f4eb3f0743b2c2cf718a8399828053e' }
                            # sends data over transfer socket
AMBA_GET_MEDIA_INFO = 0x402 # param: filename
                            # > {"msg_id": 1026, "param": "/tmp/fuse_d/DCIM/129MEDIA/YDXJ2007.jpg"}
                            # < { rval: 0, msg_id: 1026, size: 2711430, date: '2016-06-17 02:28:12', resolution: '4608x2592', media_type: 'img' }
# UNKNOWN           = 0x403 # param: filename, type: any integer?
                            # > {"msg_id": 1027, "param": "/tmp/fuse_d/DCIM/129MEDIA/YDXJ2007.jpg", "type": 100}
                            # < { rval: 0, msg_id: 1027 }

AMBA_DEL_FILE    = 0x501
AMBA_LS          = 0x502
AMBA_CD          = 0x503
AMBA_PWD         = 0x504
AMBA_GET_FILE    = 0x505
AMBA_PUT_FILE    = 0x506
AMBA_CANCEL_FILE = 0x507

AMBA_WIFI_RESTART = 0x601

# 0x701 - accepted but no response sent

# 0x1000001  sdcard type? { rval: 0, msg_id: 16777217, param: 'sd_hc' }
# 0x1000002  -13
# 0x1000003  -30 with param, -25 no param
# 0x1000004  -13
# 0x1000005  start quick record
# 0x1000006  -14 with param, -13 no param
# 0x1000007  -14 with param, -13 no param
# 0x1000008  another wifi restart?
# 0x1000009  ? rval 0
# 0x100000A  ? rval 0
# 0x100000B  take photo while video is recording - event piv_complete
# 0x100000C  configure capture mode - param: precise quality cont.;5.0 sec
# 0x100000D  ?? sent with no
# 0x100000E  ?? stop mabye?
# 0X100000F  bind bluetooth devices?
# 0x1000010  unbind bluetooth devices? - { type: 'btc_delete_all_binded_dev', param: '3' }
# 0x1000011  -13
# 0x1000012  ? rval 0
# 0x1000013  unzip firmware?
# 0x1000014  last captured photo? - { rval: 0, msg_id: 16777236, param: '/tmp/fuse_d/DCIM/100MEDIA/YDXJ0003.jpg' }
# 0x1000015  { rval: 0, msg_id: 16777237, param: '7743' }
# 0x1000016  -14
# 0x1000017  invalid message id -23
# 0x1000018  invalid message id -23
# 0x1000019  -14
# 0x100001A  dumps firmware log to /DCIM/firmware.log
#            { rval: 0, msg_id: 16777242, error: '-2' } / { rval: 0, msg_id: 16777242, param: '/DCIM/firmware.log' }

AMBA_BOSS_LINUX_SET_SOFTAP_CONFIG = 0x2000001 # does not work?
AMBA_BOSS_LINUX_GET_SOFTAP_CONFIG = 0x2000002 # sends invalid JSON
AMBA_BOSS_LINUX_RESTART_WEB_SERVER = 0x2000006

# something to do with firmware updates
# 0x4000001 - ?
# 0x4000002 - ?
# 0x4000003 - rval 0
# 0x4000004 - rval 0

shallowCopy = (obj) ->
  rv = {}
  for key of obj
    rv[key] = obj[key]
  return rv

Buffer.allocUnsafe ?= (size) -> new Buffer size

errorMessages =
  '0': 'Ok'
  '-1': 'File not found'
  '-3': 'Other device connected' # seems to happen when the iOS app is connected to the camera
  '-4': 'Unauthorized' # token invalid or not provided
  '-9': 'Invalid arguments'
  '-13': 'Invalid value'
  '-14': 'Setting already at requested value'
  '-15': 'Setting not writable'
  '-23': 'Invalid message id'
  '-26': 'Invalid path'

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

class YiFileReadable extends stream.Readable

  CHUNK_SIZE = 512000
  MAX_ERRORS = 5

  constructor: (@filename, @control) ->
    @offset = 0
    @errors = 0
    super

  _read: ->
    if @size? and @offset >= @size
      @push null
      return
    @control.getFileChunk @filename, @offset, CHUNK_SIZE, (error, chunk, totalSize) =>
      if error?
        if error.code is -1
          error.message = "File '#{ @filename }' not found."
          @emit 'error', error
          return
        console.log "WARNING: Error when reading chunk at offset #{ @offset } of #{ @filename }, #{ error.message }"
        if ++@errors > MAX_ERRORS
          @emit 'error', error
        else
          do @push
          setTimeout (=> @read 0), 1000
      else
        @size = totalSize
        @offset += chunk.length
        @push chunk

class YiFileWritable extends stream.Writable

  constructor: (@filename, @control) ->
    @offset = 0
    super

  _write: (chunk, encoding, callback) ->
    @control.putFileChunk @filename, @offset, chunk, (error) =>
      unless error?
        @offset += chunk.length
      else
        if error.code is -13
          error.message = "File '#{ @filename }' already exists."
      callback error


class YiControl extends events.EventEmitter

  defaults =
    cameraHost: '192.168.42.1'
    cmdPort: 7878
    transferPort: 8787
    cmdTimeout: 5000
    transferTimeout: 5000

  constructor: (@options={}) ->
    @options[key] ?= defaults[key] for key of defaults

    @token = null
    @cmdQueue = []
    @chunkQueue = []

    @connect()

  connect: ->
    @open = true
    @cmdSocket = new net.Socket
    @cmdSocket.connect
      port: @options.cmdPort
      host: @options.cameraHost

    @cmdParser = new YiParser
    @cmdParser.on 'data', @handleMsg.bind(this)
    @cmdSocket.pipe @cmdParser

    @cmdSocket.setTimeout @options.cmdTimeout
    @cmdSocket.on 'timeout', =>
      # TODO: some sort of heartbeat to keep the timeout from triggering
      if @cmdSocket.readyState isnt 'open' or @activeCmd?
        @cmdSocket.destroy()

    @cmdSocket.on 'connect', =>
      @emit 'connected'
      do @getToken

    @cmdSocket.on 'error', (error) ->
      console.log "WARNING: Socket error, #{ error.message }"

    @cmdSocket.on 'close', =>
      if cmd = @activeCmd
        @activeCmd = null
        clearTimeout cmd.timer
        cmd.callback new Error 'Socket closed'
      if @open
        console.log "WARNING: Socket closed, trying to reconnect..."
        setTimeout (=> do @connect), 1000

  close: ->
    @open = false
    @cmdSocket?.destroy()
    @transferSocket?.destroy()
    @cmdSocket = null
    @transferSocket = null

  setupTransfer: ->
    @transferSocket = new net.Socket
    @transferSocket.on 'data', (@handleTransfer.bind this)
    @transferSocket.on 'connect', (@processChunk.bind this)
    @transferSocket.on 'error', (error) ->
      console.log "WARNING: Transfer socket error, #{ error.message }"
    @transferSocket.on 'close', =>
      @transferSocket = null
      do @processChunk
      if @activeChunk?
        console.log "WARNING: Transfer socket unexpectedly closed"
        chunk = @activeChunk
        @activeChunk = null
        chunk.callback new Error 'Socket unexpectedly closed'
    @transferSocket.connect
      port: @options.transferPort
      host: @options.cameraHost

  getToken: ->
    @sendCmd {msg_id: 257, token: 0, heartbeat: 1}, true, (error, result) =>
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

    cmd = {data, callback}

    cmd.timeout = =>
      if cmd is @activeCmd
        @activeCmd = null
      else
        @cmdQueue.splice (@cmdQueue.indexOf cmd), 1
      cmd.callback new Error 'Timed out'

    cmd.timer = setTimeout cmd.timeout, @options.cmdTimeout

    if highPriority
      @cmdQueue.unshift cmd
    else
      @cmdQueue.push cmd

    setImmediate => do @runQueue

  runQueue: ->
    if @cmdSocket?.readyState isnt 'open' or @activeCmd? or @cmdQueue.length is 0
      return

    @activeCmd = cmd = @cmdQueue.shift()

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
        error = new Error "#{ resolveErrorMessage data.rval } (msg_id: #{ data.msg_id })"
        error.code = data.rval
        if error.code is -4
          @getToken()
      clearTimeout cmd.timer
      if data.msg_id is 16777220 and data.rval is 0
        # wait for the photo_taken event
        cmd.timer = setTimeout cmd.timeout, @options.cmdTimeout
        @activeCmd = cmd
      else
        cmd.callback error, data
    else if data.msg_id is 7
      delete data['msg_id']
      @emit 'event', data
      switch data.type
        when 'get_file_complete', 'put_file_complete'
          if @activeChunk?
            @activeChunk._md5 = data.md5sum ? data.param[1].md5sum
            do @finalizeChunk
          else
            console.log "WARNING: Got #{ data.type } event with no active chunk!"
        when 'put_file_fail'
          if @activeChunk?
            @transferError 'Transfer failed.', 'EFAIL'
        when 'photo_taken'
          filename = data.param
          if @activeCmd? and @activeCmd.data.msg_id is 16777220
            cmd = @activeCmd
            @activeCmd = null
            clearTimeout cmd.timer
            cmd.callback null, filename
          else
            @emit 'photo_taken', filename
        else
          @emit data.type, data.param
    else
      console.log 'WARNING: Got unknown message', data
    do @runQueue

  getFileChunk: (filename, offset, size, callback) ->
    @chunkQueue.push {filename, offset, size, callback, type: 'get'}
    do @processChunk

  putFileChunk: (filename, offset, buffer, callback) ->
    @chunkQueue.push {filename, offset, buffer, callback, type: 'put'}
    do @processChunk

  getMediaInfo: (filename, callback) ->
    @sendCmd {msg_id: 1026, param: filename}, callback

  deleteFile: (filename, callback) ->
    @sendCmd {msg_id: 1281, param: filename}, (error, result) ->
      if error?
        if error.code is -1
          error.message = "File '#{ filename }' does not exist."
      callback error, result

  listDirectory: (dirname, callback) ->
    dirname += '/' if dirname[-1..] isnt '/' # camera crashes when listing a directory w/o trailing slash
    @sendCmd {msg_id: 1282, param: "#{ dirname } -S -D"}, (error, result) ->
      unless error?
        rv = []
        for item in result.listing
          for name, meta of item
            parts = meta.split '|'
            size = parseInt (parts[0].replace ' bytes', '')
            date = new Date parts[1]
            rv.push {name, size, date}
      callback error, rv

  createReadStream: (filename) -> new YiFileReadable filename, this

  createWriteStream: (filename) -> new YiFileWritable filename, this

  transferError: (message='Timed out waiting for transfer socket.', code='ETIMEOUT') =>
    chunk = @activeChunk
    @activeChunk = null
    @transferSocket.destroy()
    @transferSocket = null
    error = new Error message
    error.code = code
    chunk.callback error

  processChunk: ->
    if @activeChunk? or @chunkQueue.length is 0
      return

    unless @transferSocket?
      do @setupTransfer
      return

    @transferSocket.setTimeout @options.transferTimeout
    @transferSocket.once 'timeout', @transferError

    chunk = @activeChunk = @chunkQueue.shift()
    chunk._pos = 0

    handleError = (error) =>
      chunk.callback error
      @activeChunk = null
      @transferSocket?.setTimeout 0
      @transferSocket?.removeListener 'timeout', @transferError

    switch chunk.type
      when 'get'
        @sendCmd {msg_id: 1285, param: chunk.filename, offset: chunk.offset, fetch_size: chunk.size}, (error, result) =>
          if error?
            handleError error
            return
          chunk.size = result.rem_size
          chunk._totalSize = result.size
      when 'put'
        md5sum = crypto
          .createHash 'md5'
          .update chunk.buffer
          .digest 'hex'
        offset = chunk.offset
        size = chunk.buffer.length + offset
        @sendCmd {msg_id: 1286, param: chunk.filename, offset, size, md5sum}, (error, result) =>
          if error?
            handleError error
            return
          @transferSocket.write chunk.buffer, =>
            chunk._complete = true
            do @processChunk

  finalizeChunk: ->
    unless chunk = @activeChunk
      return
    if chunk._md5? and chunk._complete
      # the checksum only matches what is sent if the whole file is asked for with fetch_size
      # i guess they have some bug with calculating it for partial requests
      # checksum = crypto
      #   .createHash 'md5'
      #   .update chunk.buffer
      #   .digest 'hex'
      @activeChunk = null
      @transferSocket.setTimeout 0
      @transferSocket.removeListener 'timeout', @transferError
      chunk.callback null, chunk.buffer, chunk._totalSize
      do @processChunk

  handleTransfer: (data) ->
    unless chunk = @activeChunk
      console.log 'WARNING: Got transfer data without active chunk!', data.length
      return

    if chunk.type is 'put'
      console.log 'WARNING: Got transfer data when writing chunk!', data.length
      return

    if data.length is chunk.size
      chunk.buffer = data
      chunk._pos = data.length
    else
      chunk.buffer ?= Buffer.allocUnsafe chunk.size
      chunk._pos += data.copy chunk.buffer, chunk._pos

    if chunk._pos >= chunk.size
      chunk._complete = true
      do @finalizeChunk

  getSettings: (callback) ->
    @sendCmd {msg_id: 3}, (error, result) ->
      unless error?
        rv = {}
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

  capturePhoto: (callback) ->
    @sendCmd {msg_id: 16777220, param: 'precise quality;off'}, true, callback

  getStatus: (callback) ->
    @sendCmd {msg_id: 1, type: 'app_status'}, (error, result) ->
      unless error?
        rv = result.param
      callback error, rv


module.exports = YiControl
