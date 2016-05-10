
'IQ SDK. Use only the public methods, not prefixed by "private_".
'To be used correctly, init should be called when the player is loaded. Then setContentMetadata
'should be called whenever the video content changes. The notification period for the video content
'should also be set byt the user to one second if possible, for optimal event reporting.
'Finally, reportExit should be called when the video display is exited for whatever reason(error,
'end of video, user exit, etc')
function IQ() as Object
    return{

        '==================================PUBLIC API=============================================='
        'Initialization method : Should be called when the player is created

        init : function(Pcode, TestMode = false as Boolean, callback = emptyCallback, testMObject = createObject("roAssociativeArray")) as Void
            m.private_debugEnabled = false
            m.contentMetadata = {} 'Video metadata (duration, type, etc. Provided by the user
            m.liveContent = false 'A boolean that should be true when a live event is shown'    
            m.dateTime = createObject("roDateTime") 'dateTime object used to compute the current time
            m.pendingEvents = []'List of pending events to be reported
            m.flushTime& = 0'Next time (in MS since epoch) where we should flush our events
            m.priorities = {LOW : 0, MEDIUM : 1, HIGH : 2} 'Event priorities 
            m.priorityIntervals = [10000,5000,1000] 'Event time priority intervals in MS
            m.base = {} 'Base JSON object when send with each report request
            m.serverAddress = "http://l.ooyala.com/v3/analytics/events" 'IQ endpoint
            m.xfer = CreateObject("roURLTransfer") 'Network object used to make async HTTP requests to our backend
            m.xfer.SetURL(m.serverAddress) 'We set our server address
            m.xfer.AddHeader("Content-Type", "application/json") 
            m.buckets ={ 'All the data about the buckets (1/40th of a video)
                watched : [], 'Array containing all the buckets. If bucket 3 has been watched, then
                                ' watched[3] will be set to true
                currents : [], ' The current buckets being viewed(could be more than one bucket since
                                ' the precision of the time is in seconds in Roku')
                startingTimes : [], 'The bucket starting times 
                bucketCount : 40 ' The number of buckets
                watchedCount : 0 ' Total count of buckets which have been watched
            }
            m.lastPlayheadPosition = 0 ' Last playhead position (used for seeking detection)
            m.notificationPeriod = 1 'Video notification in seconds. Should be set to 1 by the SDK user
            m.timePlayed = 0 'Time played in the video since the last time played event
            m.hasContentBeenDisplayed = false 'Set to true when the first video started event is received
            m.nextPlaythroughPercentReported = 25 'Next playthrough percent to report. We only report 25/50/75/100

            m.testMode = TestMode
            m.baseArrayObject = {} 'Copy of base json object created for testing'

            if(m.TestMode)    
                m.callback = callback
                m.testMobject = testMobject
            end if 

            m.eventSequenceNumber = 0'Event sequence number increased for each event
            m.events = {    
                            PLAYER_LOAD : { name: "playerLoad", priority : m.priorities.HIGH},'Reported when we init our library
                            DISPLAY : { name:"display",priority : m.priorities.HIGH}, ' Reported in setContentMetadata
                            PLAY_REQUESTED : { name:"playRequested",priority : m.priorities.HIGH}, 'Reported
                            VIDEO_STARTED : { name:"videoStarted",priority : m.priorities.HIGH},'Reported
                            PLAYTHROUGH_PERCENT: { name:"playthroughPercent",priority : m.priorities.HIGH}, 'Reported
                            PERCENTAGE_WATCHED : { name:"percentageWatched",priority : m.priorities.MEDIUM}, 'Reported
                            BUCKETS_WATCHED : { name:"bucketWatched",priority : m.priorities.MEDIUM},'Reported
                            REPLAY : { name:"replay",priority : m.priorities.HIGH},'Reported by users
                            SEEK : { name:"seek",priority : m.priorities.MEDIUM},'Reported
                            PAUSE : { name:"pause",priority : m.priorities.MEDIUM},'done in reportPause
                            RESUME : { name:"resume",priority : m.priorities.MEDIUM},'done in reportResumed
                            TOTAL_TIME_PLAYED : { name:"timePlayed",priority : m.priorities.LOW},'Reported
                            PLAYHEAD_UPDATE : { name : "playheadUpdate", priority : m.priorities.LOW}, 'Reported with the playback position updates
                            CUSTOM: { name:"custom", priority : m.priorities.MEDIUM}'Reported
                            }    
           
           m.base.AddReplace("analyticsSdkName","ooyala-roku-analytics-sdk") 
           m.base.AddReplace("analyticsSdkVersion","1.0.1") 
           m.base.AddReplace("player", m.private_getPlayerInfo())
           m.base.AddReplace("device", m.private_getDeviceInfo())
           m.base.AddReplace("sessionId",m.private_makeSessionID())'We can start preparing our JSON
           m.base.AddReplace("sessionStartTime", m.dateTime.ToISOSTRING())
           m.base.AddReplace("pcode", Pcode)
           m.private_reportPlayerLoad() 'We can also report the player load event, since init() should be called
                                '  when we have loaded the player 
        end function

        emptyCallback : function() as Void
            print " called empty function"
        end function

        setUserInfo : function (userInfo as Object) as Void
            m.base.AddReplace("user",userInfo)
        end function

        setGeoInfo : function (geoInfo as Object) as Void
            m.base.AddReplace("geo",geoInfo)
        end function

        'This method should be called everytime a new video is givent to the player.  The metadata 
        '  should look like this : {duration : 42,assetId : "AdDgFFGgEergergwrrehEj" , assetType: "external"}   
        setContentMetadata : function (metadata as Object) as Void
            m.contentMetadata = metadata
            'If the conten t shown is live, the content metadata's duration is set to -1'
            if(m.contentMetadata.duration = -1)
                m.liveContent = true
            end if 
            m.dateTime.mark()
            m.asset = {}
            m.asset.AddReplace("id", metadata.assetId)
            m.asset.AddReplace("idType", metadata.assetType)
            m.base.AddReplace("asset",m.asset) 
            m.hasContentBeenDisplayed = false
            m.timePlayed = 0 
            m.buckets.watchedCount = 0   
            m.private_reportDisplay()
            for i = 0 to (m.buckets.bucketCount -1) step 1
                m.buckets.watched[i] = false
                m.buckets.currents[i] = false
            end for
            m.private_computeBucketsStartingTimes()
        end function        
        
        'Report a custom event
        reportCustomEvent : function(name, metadata) as Void
            event = m.private_makeStandardEvent(m.events.CUSTOM.name)
            event.AddReplace("customEventName", name)
            For Each key in metadata
                event.AddReplace(key, metadata[key])
            end For

            m.private_addPendingEvent(event,m.events.CUSTOM.priority)
        end function

        'Report video replay
        reportReplay : function() as Void
            m.private_buildAndAddEventToPending(m.events.REPLAY)
        end function

        'Should be called when show() is called on the video
        reportPlayRequested : function(isAutoplay as Boolean) as Void
            event = m.private_makeStandardEvent(m.events.PLAY_REQUESTED.name)
            event.AddReplace("isAutoPlay", isAutoplay)
            m.private_addPendingEvent(event,m.events.PLAY_REQUESTED.priority)
        end function
        
        'This method should be called when the event loop if the video player is exited (for any reason)
        ' This allows the SDK to make sure all the events have been flushed to IQ
        reportEventLoopExit : function() as Void
            m.private_flushPendingEvents()
        end function
        
        'Allows the SDK to handle event and report them to IQ.
        'This method should be called in every iteration of the event loop. The event loop should 
        ' not have a latency higher than one second:
        '   - the notificationPeriod of the video should be set to one second'
        '   - the event should have a waiting timeout of one second (msg = wait(1000, video.GetMessagePort()))   
        handleEvent: function(event) as Void
           'First we check if we got a videoScreenEvent or a VideoPlayerEvent
           if (type(event) = "roVideoScreenEvent") or (type(event) = "roVideoPlayerEvent") or ((type(event) = "roAssociativeArray") and (event.DoesExist("getType")))
                if event.isStreamStarted()
                    m.private_reportVideoStarted()
                else if event.isPaused()
                    m.private_reportVideoPaused()
                else if event.isPlaybackPosition()
                    'If the content shown is live, no duration related event should be reported'
                    if not m.liveContent
                        m.private_reportPlaybackPosition(event.GetIndex())
                    end if     
                    m.private_reportPlayheadUpdate(event.GetIndex())
                else if event.isRequestFailed()
                else if event.isStatusMessage()
                else if event.isFullResult()
                    m.private_reportFullPlayback()
                else if event.isPartialResult()
                else if event.isResumed()
                    m.private_reportResumed()
                end if
            end if
            'We flush the events if it is time
            m.private_flushPendingEventsIfNecessary()   
        end function
        
        '===========================Private methods============================

        'Gets the player info
        private_getPlayerInfo : function() as Object
            roDeviceInfo = CreateObject("roDeviceInfo")
            playerInfo = {}
            playerInfo.AddReplace("name", "roku")
            playerInfo.AddReplace("version", roDeviceInfo.getVersion())
            playerInfo.AddReplace("id", "roku")
            return playerInfo
        end function

        'Gets the device related info
        private_getDeviceInfo : function() as Object
            roDeviceInfo = CreateObject("roDeviceInfo")
            info = {}
            deviceInfo = {}
            deviceInfo.AddReplace("os", "rokuos")
            deviceInfo.AddReplace("osVersion", roDeviceInfo.getVersion())
            deviceInfo.AddReplace("deviceBrand", "Roku")
            deviceInfo.AddReplace("browser", "roku_sdk")
            deviceInfo.AddReplace("deviceType", "settop")
            deviceInfo.AddReplace("model", roDeviceInfo.getModel())
            info.AddReplace("deviceInfo",deviceInfo)
            info.id = roDeviceInfo.GetDeviceUniqueId()
            return info
        end function
        
        'This function can be used to override the device info for testing
        private_setDeviceInfo : function(os as String, osVersion as String, deviceBrand as String, deviceType as String, model as String, id as String) as Void
            info = {}
            deviceInfo = {}
            deviceInfo.AddReplace("os", os)
            deviceInfo.AddReplace("osVersion", osVersion)
            deviceInfo.AddReplace("deviceBrand", deviceBrand)
            deviceInfo.AddReplace("deviceType", deviceType)
            deviceInfo.AddReplace("model", model)
            info.deviceInfo = deviceInfo
            info.id = id
            m.base.AddReplace("device", info)
        end function

        'Computes the buckets start times depending on the video metadata
        private_computeBucketsStartingTimes : function() as Void
            
            bucketDuration = m.contentMetadata.duration/40 'bucket duration 
            
            for i = 0 to (m.buckets.bucketCount - 1) step 1
                startingTime% = i * bucketDuration
                m.buckets.startingTimes[i] = startingTime%
            end for

        end function
        
        'Checks if it is time to flush the event and flushes them when necessary
        private_flushPendingEventsIfNecessary : function() as Void
           'We will look at the current time and the flush time, whis is the next time we should flush
           ' the events
           if (m.private_getCurrentTimeMS() > m.flushTime&)
                m.private_flushPendingEvents()
           end if     
        end function
        
        'Makes a UUID style session ID from the Roku's RNG
        private_makeSessionID : function() as String
            GetRandomHexString = function (length As Integer) As String
                hexChars = "0123456789ABCDEF"
                hexString = ""
                For i = 1 to length
                    hexString = hexString + hexChars.Mid(Rnd(16) - 1, 1)
                Next
                Return hexString
            End Function
            
            return  GetRandomHexString(8) + "-" + GetRandomHexString(4) + "-" + GetRandomHexString(4) + "-" + GetRandomHexString(4) + "-" + GetRandomHexString(12)
        end function
        
        'Returns the current time since Epoch in milliseconds
        private_getCurrentTimeMS : function() 
            m.dateTime.mark()'Update the dateTime object with the current time
            currentTimeMS& = m.dateTime.AsSeconds() 
            currentTimeMS& = currentTimeMS& * 1000 + m.dateTime.GetMilliseconds()
            return currentTimeMS&
        end function
        
        'Adds an event to the event list and computes a new flushTime& depending on its priority
        private_addPendingEvent : function(event as Object ,priority as Integer) as Void
            if priority > m.priorities.HIGH
                m.private_debug("IQ : Wrong event priority entered :", priority) 
                return
            end if
            
            eventsInQueue = m.pendingEvents.Count()
            
            if(eventsInQueue = 0)
                m.flushTime& = m.private_getCurrentTimeMS() + m.priorityIntervals[priority]
            else  
                m.flushTime& = m.private_min(m.flushTime&, m.private_getCurrentTimeMS() + m.priorityIntervals[priority])
            end if
            
            m.pendingEvents.Push(event)
            'We increment the sequence number for each new event
            m.eventSequenceNumber = m.eventSequenceNumber + 1 
        end function
        
        'Event factory. A standard event is an event with the private_minimum info needed by IQ
        private_makeStandardEvent : function(name as String) as Object
            baseEvent ={}
            m.dateTime.mark()
            baseEvent.setModeCaseSensitive()
            baseEvent.addReplace("eventName", name)
            baseEvent.addReplace("sequenceNum", m.eventSequenceNumber)
            baseEvent.addReplace("time", m.dateTime.ToISOSTRING())
            return baseEvent
        end function
     
        'Creates a standard event and adds it to the pending list
        private_buildAndAddEventToPending : function(eventType as Object) as Void
            event = m.private_makeStandardEvent(eventType.name)       
            m.private_addPendingEvent(event,eventType.priority)
        end function
         
        'Reports the player load event(at IQ object init)
        private_reportPlayerLoad : function() as Void
            m.private_debug("Player load",invalid)
            m.private_buildAndAddEventToPending(m.events.PLAYER_LOAD)
        end function
        
        'Reports the video started event
        private_reportVideoStarted : function() as Void
            m.private_debug("Start event", invalid)
            if m.hasContentBeenDisplayed = false
                'If the content hadn't been displayed yet
                m.private_buildAndAddEventToPending(m.events.VIDEO_STARTED)
                m.hasContentBeenDisplayed = true
            else
                'It's probably a seek operation, but we'll detect it with the playhead position
            end if           
        end function    
        
        'Reports the video paused event
        private_reportVideoPaused : function() as Void
            m.private_buildAndAddEventToPending(m.events.PAUSE) 
        end function
        
        'Reports the video resumed event
        private_reportResumed : function() as Void
            m.private_buildAndAddEventToPending(m.events.RESUME) 
        end function

        'Reports the dislay event
        private_reportDisplay : function() as Void
            m.private_debug( "Display", invalid)
            m.private_buildAndAddEventToPending(m.events.DISPLAY)
        end function
        
        
        'Reports the playback finished event.
        private_reportFullPlayback : function() as Void
            m.private_debug("Full playback",invalid)
            ' We flush all the remaining events
            m.private_flushPendingEvents()
        end function
        
        'Processes the playback position update and reports the appropriate events
        private_reportPlaybackPosition : function(seconds as Integer) as Void
            m.private_debug("Playback position : ", seconds)

            'If we're not seeking, we update the total time played and we update the played/not played
            'buckets
            if not m.private_userIsSeeking(seconds)
                m.timePlayed = m.timePlayed + m.notificationPeriod  
                bucketsSeen = m.private_findBucketsForPlayheadPosition(seconds)
                m.private_addViewedBuckets(bucketsSeen)
            else
                'Or we report seeking
                m.private_reportUserSeek(m.lastPlayheadPosition,seconds)
            end if
            m.lastPlayheadPosition = seconds
        end function

        'Deterprivate_mines if the user is seeking
        private_userIsSeeking : function(position as Integer) as Boolean
            'To detect seeking, we just compute the absolute difference between the current playhead
            'position and the previous one. If it is bigger than the notification period, we are seeking
            if Abs(position - m.lastPlayheadPosition) > m.notificationPeriod
                m.private_debug("Seeking detected",invalid)
                return true
            end if

            return false
        end function

        'Reports the user seeking event
        private_reportUserSeek : function(fromSeconds as Integer,toSeconds as Integer) as Void
            event = m.private_makeStandardEvent(m.events.SEEK.name)
            event.addReplace("fromMillis", fromSeconds * 1000)
            event.addReplace("toMillis", toSeconds * 1000)
            m.private_addPendingEvent(event,m.events.SEEK.priority)
        end function

        'Gets the current viewed bucket(s) and updates the bucket watched list if needed
        private_addViewedBuckets : function(bucketArray as Object) as Void

            for each bucketIndex in bucketArray
                'We report percentage watched
                if m.buckets.watched[bucketIndex] = false
                    m.buckets.watched[bucketIndex] = true
                    m.private_reportBucketWatchedFirstTime(bucketIndex)
                end if
                'We report buckets watched    
                if m.buckets.currents[bucketIndex] = false
                    m.private_reportBucketWatched(bucketIndex)
                end if
            end for
            'Then we refresh our currently watched bucket array
            m.private_clearCurrentBucketArray()
            for each bucketIndex in bucketArray
                m.buckets.currents[bucketIndex] = true
            end for
        end function

        'Resets the currently watched bucket array
        private_clearCurrentBucketArray : function() as Void
            for i = 0 to (m.buckets.bucketCount -1) step 1
                m.buckets.currents[i] = false
            end for
        end function
        
        'Reports the total time played in milliseconds
        private_reportTimePlayed : function() as Void
            event = m.private_makeStandardEvent(m.events.TOTAL_TIME_PLAYED.name)
            event.AddReplace("timePlayedMillis",m.timePlayed * 1000)
            m.private_addPendingEvent(event,m.events.TOTAL_TIME_PLAYED.priority)
            m.timePlayed = 0
        end function

        'Reports the current playhead position in MS
        private_reportPlayheadUpdate : function(position) as Void
            event = m.private_makeStandardEvent(m.events.PLAYHEAD_UPDATE.name)
            event.AddReplace("playheadPositionMillis",position * 1000)
            m.private_addPendingEvent(event,m.events.PLAYHEAD_UPDATE.priority)
        end function

        'Reports the total percentage of video that has been watched
        private_reportPlaythroughPercent : function() as Void
            'Compute the percentage
            percentage = (m.buckets.watchedCount / m.buckets.bucketCount) * 100
            if(percentage >= m.nextPlaythroughPercentReported)
                'Build the event
                event = m.private_makeStandardEvent(m.events.PLAYTHROUGH_PERCENT.name)
                event.AddReplace("percent",Cint(m.nextPlaythroughPercentReported))
                'Add the event to the pending list 
                m.private_addPendingEvent(event,m.events.PLAYTHROUGH_PERCENT.priority)
                m.nextPlaythroughPercentReported = m.nextPlaythroughPercentReported + 25
            end if
        end function

        'Reports a bucket view. This is called every time we enter a new bucket(even if already watched)
        private_reportBucketWatched : function(index as Integer) as Void
            event = m.private_makeStandardEvent(m.events.BUCKETS_WATCHED.name)
            bucket ={}
            'Buckets go from 0 to 39 in our array representation
            event.AddReplace("startMille", index * 25 + 1)
            event.AddReplace("endMille", index * 25 + 25)
            'Add the event to the list of pending events
            m.private_addPendingEvent(event, m.events.BUCKETS_WATCHED.priority)
        end function

        'Reports a bucket view. This is done only once per bucket
        private_reportBucketWatchedFirstTime : function(index as Integer) as Void
           event = m.private_makeStandardEvent(m.events.PERCENTAGE_WATCHED.name)
           bucket ={}
           'Buckets go from 0 to 39 in our representation
           event.AddReplace("startMille", index * 25 + 1)
           event.AddReplace("endMille", index * 25 + 25)
           'Add to the pending events
           m.private_addPendingEvent(event, m.events.PERCENTAGE_WATCHED.priority)
           'We add one more bucket to the count of bucket watched(used to compute percentage)
           m.buckets.watchedCount = m.buckets.watchedCount + 1
        end function

        ' Finds all the buckets corresponding to one playhead position.It is possible to have more than one
        ' bucket per position since positions are represented in integer. Therefore if we have a 
        ' video shorter than 40 seconds, we could have two or more buckets starting at the same timestamp
        private_findBucketsForPlayheadPosition : function(position as Integer) as Object
            found = false
            i = 0
            bucketArray = []
            'We iterate trhough the list to find the first bucket with a greater starting time than
            ' our bucket
            while found = false
                if((i = m.buckets.bucketCount) or (m.buckets.startingTimes[i] > position))
                    'Then the previous bucket is the bucket we are actually watching
                    bucketArray.push(i - 1)
                    'Then we will look if there are other buckets with the same starting time
                    j = i - 2
                    while m.buckets.startingTimes[j] = m.buckets.startingTimes[i-1]
                        bucketArray.unshift(j)
                        j = j - 1
                    end while
                    'We have found the buckets we were looking for
                    found = true
                else
                    i = i + 1
                end if
            end while
            'We return our list of bucket

            return bucketArray
        end function

        'Flushes the pending event by encoding a JSON and sending it to Ooyala IQ endpoint 
        private_flushPendingEvents : function() as Void
            'Check first if there are events waiting to be sent
            if (m.pendingEvents.Count() > 0)
                'Report the total time played 
                m.private_reportTimePlayed()
                'Report the completion of content playback if it is not a live content
                if not m.liveContent
                    m.private_reportPlaythroughPercent()
                end if     
                'Set the current time of the request
                m.dateTime.mark()
                m.base.AddReplace("clientTime", m.dateTime.ToISOSTRING()) 
                'Prepare and send the JSON
                m.base.events = m.pendingEvents
                i = m.pendingEvents.count()
                if(m.testMode)
                    m.baseArrayObject = m.base 
                    m.callback(m.testMobject) 
                end if     

                json =  formatJSON(m.base)
                m.private_sendJSONToServer(json)
                'Reset the list of pending events
                m.pendingEvents =[]
            end if
        end function

        'This method takes a JSON object and sends it over HTTP POST to Ooyala IQ endpoint
        private_sendJSONToServer : function(json) as Void
            m.private_debug(json,invalid)   
            m.xfer.AsyncPostFromString(json)    
        end function
        
        'Utility function to compare numbers
        private_min : function(a as Double, b as Double) as Double
            if (a > b)
                return b
            end if 
            return a
        end function

        'Prints to the console if debugEnabled is true
        'Use invalid as obj if there is only text to display
        private_debug : function(text as String, obj as Object)
            if (m.private_debugEnabled = true)
                if(obj = invalid)
                    print text
                else
                    print text;obj
                end if
            end if

        end function
        'Utility function for testing.'
        private_getBaseJsonObject: function() as Object
            return  m.baseArrayObject
        end function
        'Utility function for testing.'
        private_clearMobject: function () as Void
            m.clear()
        end function

    }

end function