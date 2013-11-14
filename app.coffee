conf    = require './config'
Twit    = require 'twit'
mongojs = require 'mongojs'
http    = require 'http'
_       = require 'underscore'
async   = require 'async'

__baseHtml = """
<html>
  <head>
    <link rel="stylesheet" href="//netdna.bootstrapcdn.com/bootstrap/3.0.2/css/bootstrap.min.css">
    <title>Twitter retweet streamer - Chaitanya Surapaneni</title>
  </head>
  <body class="container">
    <a href="https://github.com/schaitanya/twitter"><img style="position: absolute; top: 0; right: 0; border: 0;" src="https://s3.amazonaws.com/github/ribbons/forkme_right_red_aa0000.png" alt="Fork me on GitHub"></a>
    <div class="jumbotron">
      <h1>Twitter streamer</h1>
    </div>
    <div class="row">
      <div class="clearfix col-md-16">
        <form class="form-inline col-md-offset-3" role="form">
          <div class="form-group">
            <label class="sr-only" for="type">Search by </label>
            <select name="type" id="type" class="form-control">
              <option value="filter">Filter term</option>
              <option value="handle">Handle</option>
            </select>
          </div>
          <div class="form-group">
            <label class="sr-only" for="value">Value</label>
            <input type="text" id="value" name="value" class="form-control" placeholder="search for" required/>
          </div>
          <button class="btn btn-success" type="submit">Submit</button>
        </form>
      </div>
      <div class="clearfix col-md-16">
        <ul class="list-group" style="display:none">
        </ul>
      </div>
    </div>
  <script type="text/javascript" src="//cdnjs.cloudflare.com/ajax/libs/jquery/2.0.3/jquery.min.js"></script>
  <script type="text/javascript" src="/socket.io/socket.io.js"></script>
  <script>
  $(document).on('ready', function(){
    var socket = io.connect("//localhost:8080");
    socket.on('tweets', function(tweets) {
      var li = "";
      for(var i = 0; i < tweets.length; i++) {
        var tweet = tweets[i];
        li += "<li class='list-group-item'><span class='badge'>"+tweet.rt_count+"</span>@"+tweet.author.screen_name+": "+tweet.message+"</li>"
      }
      if(tweets.length == 0) {
        li += "<li class='list-group-item'>Still searching.... Will update periodically.</li>";
      }
      $('.list-group').html(li);
      $('.list-group').show();
    });
    socket.on('none', function() {
      $('.list-group').html('<li class="list-group-item">No results found with that query.</li>');
    });
    socket.on('user', function(query) {
      socket.emit('filter', query);
    });
    $('form').on('submit', function(e) {
      e.preventDefault();
      var type = $('#type').val();
      var value = $('#value').val();
      $('.list-group').html('');
      $('.list-group').html("<li class='list-group-item'>Searching for: "+value+"</li>");
      $('.list-group').show();
      if(type == 'handle') {
        socket.emit('handle', value);
      } else {
        socket.emit('filter', value);
      }
    });
  });
  </script>
  </body>
</html>
"""

server = http.createServer (req, res) ->
  res.end __baseHtml


mongo = mongojs conf.get("mongo:connection"), ['tweets']
mongo.tweets.ensureIndex { rt_count: 1 }
mongo.tweets.ensureIndex { filter: 1 }
mongo.tweets.ensureIndex { tid: 1 }

Tweets = mongo.tweets

T = new Twit conf.get('twitter')

stream   = null
prevSend = []

io = require('socket.io').listen(server, { log: false })
server.listen 8080, ->
  console.log 'Running server on port 8080'

io.sockets.on 'connection', (socket) ->

  alive = true

  socket.on 'disconnect', (socket) ->

    # Destroy twitter stream
    stream.stop() if stream?

  socket.on 'filter', (filter) ->
    return socket.emit 'none', null unless filter?
    query = if _.isObject filter then filter else track: filter

    stream = T.stream 'statuses/filter', query

    # Now stream the Twitter API
    stream.on 'error', (error) ->
      console.log error

    async.series [

      (callback) ->
        __checkDB filter, socket, callback

      (callback) ->
        stream.on 'tweet', (twt) ->
          return callback() unless twt?.retweeted_status?

          tweet = twt?.retweeted_status

          Tweets.update { tid: tweet?.id }, { tid: tweet?.id, filter: filter, message: tweet.text, author: tweet.user, rt_count: tweet.retweet_count }, { upsert: true }, (err, tws) ->
            __checkDB filter, socket, callback

      ], (err) ->
        #console.log 'Done iteration'

  socket.on 'handle', (handle) ->
    T.get 'users/lookup', { screen_name: handle } , (err, users) ->
      return socket.emit 'none', null if err or _.isEmpty users
      socket.emit 'user', { follow: users[0]?.id }


__checkDB = (filter, socket, callback) ->
  Tweets.find({ filter: filter }).limit(10).sort {rt_count : -1 }, (err, tweets) ->
    #return callback() if _.isEmpty tweets

    send = _.map tweets, (tweet) -> _.pick tweet, ['author', 'message', 'rt_count']
    socket.emit 'tweets', send if prevSend isnt send
    prevSend = send
    return callback()