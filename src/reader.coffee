_ = require 'underscore'
Debug = require 'debug'
request = require 'request'
{EventEmitter} = require 'events'

{ReaderConfig} = require './config'
{NSQDConnection} = require './nsqdconnection'
{ReaderRdy} = require './readerrdy'
RoundRobinList = require './roundrobinlist'
lookup = require './lookupd'


class Reader extends EventEmitter

  # Responsibilities
  # 1. Responsible for periodically querying the nsqlookupds
  # 2. Connects and subscribes to discovered/configured nsqd
  # 3. Consumes messages and triggers MESSAGE events
  # 4. Starts the ReaderRdy instance
  # 5. Hands nsqd connections to the ReaderRdy instance
  # 6. Stores Reader configurations

  # Reader events
  @ERROR: 'error'
  @MESSAGE: 'message'
  @DISCARD: 'discard'
  @NSQD_CONNECTED: 'nsqd_connected'
  @NSQD_CLOSED: 'nsqd_closed'

  constructor: (@topic, @channel, options) ->
    @debug = Debug "nsqjs:reader:#{@topic}/#{@channel}"
    @config = new ReaderConfig options
    @config.validate()

    @debug 'Configuration'
    @debug @config

    @roundrobinLookupd = new RoundRobinList @config.lookupdHTTPAddresses
    @readerRdy = new ReaderRdy @config.maxInFlight, @config.maxBackoffDuration,
      "#{@topic}/#{@channel}"
    @connectIntervalId = null
    @connectionIds = []
    return

  connect: ->
    interval = @config.lookupdPollInterval * 1000
    delay = Math.random() * @config.lookupdPollJitter * interval

    # Connect to provided nsqds.
    if @config.nsqdTCPAddresses.length
      directConnect = =>
        # Don't establish new connections while the Reader is paused.
        return if @isPaused()

        if @connectionIds.length < @config.nsqdTCPAddresses.length
          for addr in @config.nsqdTCPAddresses
            [address, port] = addr.split ':'
            @connectToNSQD address, Number(port)
        return

      delayedStart = =>
        @connectIntervalId = setInterval directConnect.bind(this), interval
        return

      # Connect immediately.
      directConnect()
      # Start interval for connecting after delay.
      setTimeout delayedStart, delay
      return
      
    # Connect to nsqds discovered via lookupd
    
    delayedStart = =>
      @connectIntervalId = setInterval @queryLookupd.bind(this), interval
      return

    # Connect immediately.
    @queryLookupd()
    # Start interval for querying lookupd after delay.
    setTimeout delayedStart, delay
    return

  # Caution: in-flight messages will not get a chance to finish.
  close: ->
    clearInterval @connectIntervalId
    @readerRdy.close()
    return

  pause: ->
    @debug 'pause'
    @readerRdy.pause()
    return

  unpause: ->
    @debug 'unpause'
    @readerRdy.unpause()
    return

  isPaused: ->
    @readerRdy.isPaused()
    return

  queryLookupd: ->
    # Don't establish new connections while the Reader is paused.
    return if @isPaused()

    # Trigger a query of the configured ``lookupdHTTPAddresses``
    endpoint = @roundrobinLookupd.next()
    lookup endpoint, @topic, (err, nodes) =>
      @connectToNSQD n.broadcast_address, n.tcp_port for n in nodes unless err
      return
    return
    
  connectToNSQD: (host, port) ->
    @debug "connecting to #{host}:#{port}"
    conn = new NSQDConnection host, port, @topic, @channel, @config

    # Ensure a connection doesn't already exist to this nsqd instance.
    return if @connectionIds.indexOf(conn.id()) isnt -1
    @connectionIds.push conn.id()

    @registerConnectionListeners conn
    @readerRdy.addConnection conn

    conn.connect()
    return

  registerConnectionListeners: (conn) ->
    conn.on NSQDConnection.CONNECTED, =>
      @debug Reader.NSQD_CONNECTED
      @emit Reader.NSQD_CONNECTED, conn.nsqdHost, conn.nsqdPort
      return

    conn.on NSQDConnection.ERROR, (err) =>
      @debug Reader.ERROR
      @debug err
      @emit Reader.ERROR, err
      return

    conn.on NSQDConnection.CONNECTION_ERROR, (err) =>
      @debug Reader.ERROR
      @debug err
      @emit Reader.ERROR, err
      return

    # On close, remove the connection id from this reader.
    conn.on NSQDConnection.CLOSED, =>
      @debug Reader.NSQD_CLOSED

      index = @connectionIds.indexOf conn.id()
      return if index is -1
      @connectionIds.splice index, 1

      @emit Reader.NSQD_CLOSED, conn.nsqdHost, conn.nsqdPort
      return

    # On message, send either a message or discard event depending on the
    # number of attempts.
    conn.on NSQDConnection.MESSAGE, (message) =>
      @handleMessage message
      return
    return
    
  handleMessage: (message) ->
    # Give the internal event listeners a chance at the events before clients
    # of the Reader.
    process.nextTick =>
      autoFinishMessage = 0 < @config.maxAttempts <= message.attempts
      numDiscardListeners = @listeners(Reader.DISCARD).length

      if autoFinishMessage and numDiscardListeners > 0
        @emit Reader.DISCARD, message
      else
        @emit Reader.MESSAGE, message

      message.finish() if autoFinishMessage
      return
    return

module.exports = Reader
