##############################################################################
#
# SageMathCloud: A collaborative web-based interface to Sage, IPython, LaTeX and the Terminal.
#
#    Copyright (C) 2016, Sagemath Inc.
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
###############################################################################

###
Chat message JSON format:

sender_id : String which is the original message sender's account id
event     : Can only be "chat" right now.
date      : A date string
history   : Array of "History" objects (described below)
editing   : Object of <account id's> : <"FUTURE">

"FUTURE" Will likely contain their last edit in the future

 --- History object ---
author_id : String which is this message version's author's account id
content   : The raw display content of the message
date      : The date this edit was sent

Example object:
{"sender_id":"07b12853-07e5-487f-906a-d7ae04536540",
"event":"chat",
"history":[
        {"author_id":"07b12853-07e5-487f-906a-d7ae04536540","content":"First edited!","date":"2016-07-23T23:10:15.331Z"},
        {"author_id":"07b12853-07e5-487f-906a-d7ae04536540","content":"Initial sent message!","date":"2016-07-23T23:10:04.837Z"}
        ],
"date":"2016-07-23T23:10:04.837Z","editing":{"07b12853-07e5-487f-906a-d7ae04536540":"FUTURE"}}
---

Chat message types after immutable conversion:
(immutable.Map)
sender_id : String
event     : String
date      : Date Object
history   : immutable.List of immutable.Maps
editing   : immutable.Map

###

# standard non-SMC libraries
immutable = require('immutable')
{IS_MOBILE, isMobile} = require('./feature')
underscore = require('underscore')

# SMC libraries
misc = require('smc-util/misc')
misc_page = require('./misc_page')
{defaults, required} = misc
{Markdown, TimeAgo, Tip} = require('./r_misc')
{salvus_client} = require('./salvus_client')

{alert_message} = require('./alerts')

# React libraries
{React, ReactDOM, rclass, rtypes, Actions, Store, redux}  = require('./smc-react')
{Button, Col, Grid, FormControl, FormGroup, ListGroup, ListGroupItem, Panel, Row, ButtonGroup, Well} = require('react-bootstrap')

{User} = require('./users')

exports.redux_name = redux_name = (project_id, path) ->
    return "editor-#{project_id}-#{path}"

class ChatActions extends Actions
    _init: () =>
        ## window.a = @  # for debugging
        # be explicit about exactly what state is in the store
        @setState
            height             : 0          # 0 means not rendered; otherwise is the height of the chat editor
            input              : ''         # content of the input box
            is_preview         : undefined  # currently displaying preview of the main input chat
            last_sent          : undefined  # last sent message
            messages           : undefined  # immutablejs map of all messages
            offset             : undefined  # information about where on screen the chat editor is located
            position           : undefined  # more info about where chat editor is located
            saved_mesg         : undefined  # I'm not sure yet (has something to do with saving an edited message)
            use_saved_position : undefined  # whether or not to maintain last saved scroll position (used when unmounting then remounting, e.g., due to tab change)

    _process_syncdb_obj: (x) =>
        if x.event != 'chat'
            # Event used to be used for video chat, etc...; but we have a better approach now, so
            # all events we care about are chat.
            return
        if x.video_chat?.is_video_chat
            # discard/ignore anything else related to the old old video chat approach
            return
        if x.history?.length > 0
            # nontrivial history -- nothing to do
        else if x.payload?
            # for old chats with payload: content (2014-2016)... plus the script @hsy wrote in the work project ;-(
            x.history = []
            x.history.push
                content   : x.payload.content
                author_id : x.sender_id
                date      : x.date
            delete x.payload
        else if x.mesg?
            # for old chats with mesg: content (up to 2014)
            x.history = []
            x.history.push
                content   : x.mesg.content
                author_id : x.sender_id
                date      : x.date
            delete x.mesg
        x.history ?= []
        if not x.editing
            x.editing = {}
        return x

    # Initialize the state of the store from the contents of the syncdb.
    init_from_syncdb: () =>
        v = {}
        for x in @syncdb.get().toJS()
            x = @_process_syncdb_obj(x)
            if x?
                v[x.date - 0] = x

        @setState
            messages : immutable.fromJS(v)

    _syncdb_change: (changes) =>
        messages_before = messages = @store.get('messages')
        if not messages?
            # Messages need not be defined when changes appear in case of problems or race.
            return
        changes.map (obj) =>
            record = @syncdb.get_one(obj)
            x = record?.toJS()
            if not x?
                # delete
                messages = messages.delete(obj.date - 0)
            else
                # TODO/OPTIMIZATION: make into custom conversion to immutable (when rewrite)
                x = @_process_syncdb_obj(x)
                if x?
                    messages = messages.set("#{x.date - 0}", immutable.fromJS(x))
        if not messages_before.equals(messages)
            @setState(messages: messages)

    send_chat: (mesg) =>
        if not @syncdb?
            # WARNING: give an error or try again later?
            return
        sender_id = @redux.getStore('account').get_account_id()
        time_stamp = salvus_client.server_time()
        @syncdb.set
            sender_id : sender_id
            event     : "chat"
            history   : [{author_id: sender_id, content:mesg, date:time_stamp}]
            date      : time_stamp
        @syncdb.save()
        @setState(last_sent: mesg)

    set_editing: (message, is_editing) =>
        if not @syncdb?
            # WARNING: give an error or try again later?
            return
        author_id = @redux.getStore('account').get_account_id()

        if is_editing
            # FUTURE: Save edit changes
            editing = message.get('editing').set(author_id, 'FUTURE')
        else
            editing = message.get('editing').set(author_id, null)

        # console.log("Currently Editing:", editing.toJS())
        @syncdb.set
            history : message.get('history').toJS()
            editing : editing.toJS()
            date    : message.get('date')

    # Used to edit sent messages.
    # **Extremely** shockingly inefficient. Assumes number of edits is small.
    send_edit: (message, mesg) =>
        if not @syncdb?
            # WARNING: give an error or try again later?
            return
        author_id = @redux.getStore('account').get_account_id()
        # OPTIMIZATION: send less data over the network?
        time_stamp = salvus_client.server_time()

        @syncdb.set
            history : [{author_id: author_id, content:mesg, date:time_stamp}].concat(message.get('history').toJS())
            editing : message.get('editing').set(author_id, null).toJS()
            date    : message.get('date')
        @syncdb.save()

    set_to_last_input: =>
        @setState(input:@store.get('last_sent'))

    set_input: (input) =>
        @setState(input:input)

    saved_message: (saved_mesg) =>
        @setState(saved_mesg:saved_mesg)

    set_is_preview: (is_preview) =>
        @setState(is_preview:is_preview)

    set_use_saved_position: (use_saved_position) =>
        @setState(use_saved_position:use_saved_position)

    save_scroll_state: (position, height, offset) =>
        # height == 0 means chat room is not rendered
        if height != 0
            @setState(saved_position:position, height:height, offset:offset)


# Set up actions, stores, syncdb, etc.  init_redux returns the name of the redux actions/store associated to this chatroom
exports.init_redux = (path, redux, project_id) ->
    name = redux_name(project_id, path)
    if redux.getActions(name)?
        return name  # already initialized

    actions = redux.createActions(name, ChatActions)
    store   = redux.createStore(name)

    actions._init()

    syncdb = salvus_client.sync_db
        project_id   : project_id
        path         : path
        primary_keys : ['date']
    syncdb.once 'init', (err) =>
        if err
            mesg = "Error opening '#{path}' -- #{err}"
            console.warn(mesg)
            alert_message(type:"error", message:mesg)
            return
        actions.syncdb = syncdb
        actions.store = store
        actions.init_from_syncdb()
        syncdb.on('change', actions._syncdb_change)
    return name

exports.remove_redux = (path, redux, project_id) ->
    name = redux_name(project_id, path)
    actions = redux.getActions(name)
    actions?.syncdb?.close()
    store = redux.getStore(name)
    if not store?
        return
    delete store.state
    # It is *critical* to first unmount the store, then the actions,
    # or there will be a huge memory leak.
    redux.removeStore(name)
    redux.removeActions(name)
    return name

### Message Methods ###
exports.newest_content = newest_content = (message) ->
    return message.get('history').first()?.get('content') ? ''

exports.sender_is_viewer = sender_is_viewer = (account_id, message) ->
    account_id == message.get('sender_id')

exports.message_colors = (account_id, message) ->
    if sender_is_viewer(account_id, message)
        return {background: '#46b1f6', color: '#fff', message_class:'smc-message-from-viewer'}
    else
        return {background: '#efefef', color: '#000', lighten:{color:'#888'}}

exports.render_timeago = (message) ->
    <span
        className = "pull-right small"
        style     = {maxWidth:'20%', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis'}
        >
        <TimeAgo date={new Date(message.get('date'))} />
    </span>

NAME_STYLE =
    color        : "#888"
    marginBottom : '1px'
    marginLeft   : '10px'
    right        : 0
    whiteSpace   : 'nowrap'
    overflow     : 'hidden'
    textOverflow : 'ellipsis'    # see https://css-tricks.com/snippets/css/truncate-string-with-ellipsis/
    position     : 'absolute'    # using the "absolute in relative" positioning trick
    left         : 0
    top          : 0

exports.show_user_name = show_user_name = (sender_name) ->
    <div style={position:'relative', height:'1.2em', width:'100%'}>
        <div className={"small"} style={NAME_STYLE}>
            {sender_name}
        </div>
    </div>

exports.is_editing = is_editing = (message, account_id) ->
    message.get('editing').has(account_id)

exports.blank_column = blank_column = ->
    <Col key={2} xs={2} sm={2}></Col>

exports.render_markdown = render_markdown = (value, project_id, file_path, className) ->
    # the marginBottom offsets that markdown wraps everything in a p tag
    <div style={marginBottom:'-10px'}>
        <Markdown value={value} project_id={project_id} file_path={file_path} className={className} />
    </div>

exports.render_history_title = render_history_title =  ->
    <ListGroupItem style={borderRadius: '10px 10px 0px 0px', textAlign:'center', padding: '0px'}>
        <span style={fontStyle: 'italic', fontWeight: 'bold'}>Message History</span>
    </ListGroupItem>

exports.render_history_footer = render_history_footer = ->
    <ListGroupItem style={borderRadius: '0px 0px 10px 10px', marginBottom: '3px'}>
    </ListGroupItem>

exports.render_history = render_history = (history, user_map) ->
    if not history?
        return
    historyList = history.toJS().slice(1)  # convert to javascrip from immutable, and remove current version.
    for index, objects of historyList
        value = objects.content
        value = misc.smiley
            s: value
            wrap: ['<span class="smc-editor-chat-smiley">', '</span>']
        value = misc_page.sanitize_html(value)
        author = misc.trunc_middle(user_map.get(objects.author_id)?.get('first_name') + ' ' + user_map.get(objects.author_id)?.get('last_name'), 20)
        if value.trim() == ''
            text = "Message deleted "
        else
            text = "Last edit "
        <Well key={index} bsSize="small" style={marginBottom:'0px'}>
            <div style={marginBottom: '-10px', wordWrap:'break-word'}>
                <Markdown value={value}/>
            </div>
            <div className="small">
                {text}
                <TimeAgo date={new Date(objects.date)} />
                {' by ' + author}
            </div>
        </Well>

### ChatLog Methods ###

exports.get_user_name = get_user_name = (account_id, user_map) ->
    account = user_map?.get(account_id)
    if account?
        account_name = account.get('first_name') + ' ' + account.get('last_name')
    else
        account_name = "Unknown"

### ChatRoom Methods ###
exports.send_chat = send_chat = (e, log_container, mesg, actions) ->
    scroll_to_bottom(log_container, actions)
    e.preventDefault()
    # block sending empty messages
    if mesg.length? and mesg.trim().length >= 1
        actions.send_chat(mesg)
        clear_input(actions)

exports.clear_input = clear_input = (actions) ->
    actions.set_input('')

exports.is_at_bottom = is_at_bottom = (saved_position, offset, height) ->
    # 20 for covering margin of bottom message
    saved_position + offset + 20 > height

exports.scroll_to_bottom = scroll_to_bottom = (log_container, actions) ->
    if log_container?
        node = ReactDOM.findDOMNode(log_container)
        node.scrollTop = node.scrollHeight
        actions.save_scroll_state(node.scrollTop, node.scrollHeight, node.offsetHeight)
        actions.set_use_saved_position(false)

exports.scroll_to_position = scroll_to_position = (log_container, saved_position, offset, height, use_saved_position, actions) ->
    if log_container?
        actions.set_use_saved_position(not is_at_bottom(saved_position, offset, height))
        node = ReactDOM.findDOMNode(log_container)
        if use_saved_position
            node.scrollTop = saved_position
        else
            scroll_to_bottom(log_container, actions)

