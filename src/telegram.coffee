# Description:
#   Adds telegram adapter to hubot
#
# Configuration:
#   TELEGRAM_TOKEN *
#     must be provided, otherwise will throw
#   TELEGRAM_WEBHOOK
#     get efficient updates instead of polling for messages, must be an url without
#     trailing slash and path, example: https://hubot.example.com
#   TELEGRAM_WEBHOOK_CA
#     public key of certificate authority, used to check webhook url certificate
#   TELEGRAM_WEBHOOK_PORT
#     defaults to 8443. When `TELEGRAM_WEBHOOK` is specified a server will start on that port
#   TELEGRAM_WEBHOOK_CERT
#   TELEGRAM_WEBHOOK_KEY
#     ssl public certificate and private key respectively, both strings (PEM)
#   TELEGRAM_INTERVAL
#     polling interval when `TELEGRAM_WEBHOOK` is not specified
#
# Commands:
#   None

{ Robot, Adapter, TextMessage, EnterMessage, LeaveMessage, TopicMessage, CatchAllMessage, User } = require 'hubot'
TelegramBot = require 'node-telegram-bot-api'
Promise = require 'bluebird'

class Telegram extends Adapter

    constructor: ->
        super
        self = @

        # envs
        @token = process.env.TELEGRAM_TOKEN

        # webhooks
        @webhook = process.env.TELEGRAM_WEBHOOK || false
        @webhook_ca = process.env.TELEGRAM_WEBHOOK_CA
        @webhook_opts = {
          cert: parseInt(process.env.TELEGRAM_WEBHOOK_PORT || 8443, 10),
          key: process.env.TELEGRAM_WEBHOOK_CERT,
          port: process.env.TELEGRAM_WEBHOOK_KEY
        }

        # polling
        @interval = process.env.TELEGRAM_INTERVAL || 2000

        # opts
        @offset = 0
        @opts = {
          webHook: if @webhook then @webhook_opts else false,
          polling: if @webhook then false else { @interval }
        }

        @api = new TelegramBot(@token, @opts)

        @robot.logger.info "Telegram Adapter Bot " + @token + " Loaded..."

        # Get the bot information
        @api
          .getMe()
          .then (result) =>
              @bot_id = result.id
              @bot_username = result.username
              @bot_firstname = result.first_name
              @robot.logger.info "Telegram Bot Identified: " + @bot_firstname

              unless @bot_username is @robot.name
                  @robot.logger.warning "It is advised to use the same bot name as your Telegram Bot: " + @bot_username
                  @robot.logger.warning "Having a different bot name can result in an inconsistent experience when using @mentions"
          .catch (err) =>
              @emit 'error', err

    ###*
    # Clean up the message text to remove duplicate mentions of the
    # bot name and to strip Telegram specific characters such as the usage
    # of / when addressing a bot in privacy mode
    #
    # @param string text
    # @param int    chat_id
    #
    # @return string
    ###
    cleanMessageText: (text, chat_id) ->
        # If it is a private chat, automatically prepend the bot name if it does not exist already.
        if (chat_id > 0)
            # Strip out the stuff we don't need.
            text = text.replace(/^\//g, '').trim()

            text = text.replace(new RegExp('^@?' + @robot.name.toLowerCase(), 'gi'), '')
            text = text.replace(new RegExp('^@?' + @robot.alias.toLowerCase(), 'gi'), '') if @robot.alias
            text = @robot.name + ' ' + text.trim()
        else
            text = text.trim()

        return text

    ###*
    # Add extra options to the message packet before deliver. The extra options
    # will be pulled from the message envelope
    #
    # @param object message
    # @param object extra
    #
    # @return object
    ###
    applyExtraOptions: (text, message = {}, extra) ->
        # autoMarkdown = /\*.+\*/.test(text) or /_.+_/.test(text) or /\[.+\]\(.+\)/.test(text) or /`.+`/.test(text)
        #
        # if autoMarkdown
        #     message.parse_mode = 'Markdown'

        if extra?
            for key, value of extra
                message[key] = value

        return message

    ###*
    # Get the last offset + 1, this will allow
    # the Telegram API to only return new relevant messages
    #
    # @return int
    ###
    getLastOffset: ->
        parseInt(@offset) + 1

    ###*
    # Create a new user in relation with a chat_id
    #
    # @param object user
    # @param object chat
    #
    # @return object
    ###
    createUser: (user, chat) ->
        opts = user
        opts.name = opts.username
        opts.room = chat.id
        opts.telegram_chat = chat

        result = @robot.brain.userForId user.id, opts
        current = result.first_name + result.last_name + result.username
        update = user.first_name + user.last_name + user.username

        # Check for any changes, if the first or lastname updated...we will
        # user the new user object instead of the one from the brain
        if current != update
            @robot.brain.data.users[user.id] = user
            @robot.logger.info "User " + user.id + " regenerated. Persisting new user object."
            return user

        return result

    ###*
    # Abstract send interaction with the Telegram API
    ###
    apiSend: (chat_id, text, opts) ->
        chunks = text.match /[^]{1,4096}/g

        @robot.logger.debug "Message length: " + text.length
        @robot.logger.debug "Message parts: " + chunks.length

        Promise.mapSeries chunks, (current) =>
            @robot.logger.debug "sending #{current} to #{chat_id} with opts %j", opts
            @api.sendMessage chat_id, current, opts

    ###*
    # Send a message to a specific room via the Telegram API
    ###
    send: (envelope, strings...) ->
        text = strings.join()
        @robot.logger.debug "Input text length #{text.length}"
        data = @applyExtraOptions(text, {}, envelope.telegram)

        @apiSend envelope.room, text, data
          .then () => @robot.logger.info "Sending message to room: " + envelope.room
          .catch (err) => @emit 'error', err

    ###*
    # The only difference between send() and reply() is that we add the "reply_to_message_id" parameter when
    # calling the API
    ###
    reply: (envelope, strings...) ->
        text = strings.join()
        data = @applyExtraOptions(text, { reply_to_message_id: envelope.message.id }, envelope.telegram)

        @apiSend envelope.room, text, data
          .then (message) => @robot.logger.info "Reply message to room/message: " + envelope.room + "/" + envelope.message.id
          .catch (err) => @emit 'error', err

    ###*
    # "Private" method to handle a new update received via a webhook
    # or poll update.
    ###
    handleMessage: (message) ->
        @robot.logger.debug message
        @robot.logger.info "Receiving message_id: " + message.message_id

        # Text event
        if message.text
            @handleText message

        # Join event
        else if message.new_chat_participant
            @handleNewChatParticipant message

        # Exit event
        else if message.left_chat_participant
            @handleNewChatParticipant message

        # Chat topic event
        else if message.new_chat_title
            @handleNewChatTitle message

        else
            message.user = @createUser message.from, message.chat
            @receive new CatchAllMessage message

    ###
     * Handles text message
    ###
    handleText: (message) ->
        text = @cleanMessageText message.text, message.chat.id
        @robot.logger.debug "Received message: " + message.from.username + " said '" + text + "'"
        user = @createUser message.from, message.chat
        @receive new TextMessage user, text, message.message_id

    ###
     * Handles new chat participant event
    ###
    handleNewChatParticipant: (message) ->
        user = @createUser message.new_chat_participant, message.chat
        @robot.logger.info "User " + user.id + " joined chat " + message.chat.id
        @receive new EnterMessage user, null, message.message_id

    ###
     * Handles left chat participant
    ###
    handleLeftChatParticipant: (message) ->
        user = @createUser message.left_chat_participant, message.chat
        @robot.logger.info "User " + user.id + " left chat " + message.chat.id
        @receive new LeaveMessage user, null, message.message_id

    ###
     * Handles chat title change
    ###
    handleNewChatTitle: (message) ->
        user = @createUser message.from, message.chat
        @robot.logger.info "User " + user.id + " changed chat " + message.chat.id + " title: " + message.new_chat_title
        @receive new TopicMessage user, message.new_chat_title, message.message_id

    ###
     * Additional work after startup is successful
    ###
    started: ->
        @robot.logger.info "Telegram Adapter Started..."
        @emit "connected"
        @api.on "message", (msg) => @handleMessage msg

    ###
     * Called when hubot starts
    ###
    run: ->
        unless @token
            @emit 'error', new Error 'The environment variable "TELEGRAM_TOKEN" is required.'

        # Listen for Telegram API invokes from other scripts
        @robot.on "telegram:invoke", (method, args..., cb) =>
            @api[method].apply(@api, args).asCallback(cb)

        opts = []
        if @webhook
            endpoint = @webhook + '/' + @token
            @robot.logger.debug 'Listening on ' + endpoint
            opts.push endpoint, @webhook_ca
        else
            @robot.logger.debug 'Clearing webhook'
            opts.push ''

        @api
          .setWebHook opts...
          .then () => @started()
          .catch (err) => @emit 'error', err

exports.use = (robot) -> new Telegram robot
