#require "Twilio.class.nut:1.0.0"

// ---Configuration Parameters---
local recipientsNumber = “";  //insert phone number alerts are sent to here as +12223334444 where 222 is area code
local whitelist = “";  //insert phone number list here with each number formatted as above and separated with a space only

const fullDepth = 2210.0;
const fullOffset = 360.0;
const refillFrac = 0.2;
alertLevels <- [0.25, 0.1, 0.05, 0.03, 0];

// ---Authentication and Connection Parameters---
// Twilio
const accountSID = "";  //insert here
const authToken = "”;  //insert here
const twilioNumber = “";  //insert here
twilio <- Twilio(accountSID, authToken, twilioNumber);

// ThingSpeak
const thingSpeakUrl = "https://api.thingspeak.com/update";
local headers = {
  "Content-Type" : "application/x-www-form-urlencoded",
  "X-THINGSPEAKAPIKEY" : ""  //insert here
};

// ---Variables---
errAlertDisable <- 0; // enable/disable the measurement OOB error SMS
lastMeasurement <- {  // used to store most recent measurement
    "distance" : 0,
    "delay" : 0,
    "timeTaken" : 0
};
configs <- {            // passed to device upon startup and when changed
    "sampleTime" : 150
};
alertFlags <- array(alertLevels.len(), 1);  // used as flags for level alerts

// ---Helper Functions---
// returns the fraction of water in the tank after validating reading
function fracFull(distance) {
    return (1.00 - (distance-fullOffset)/fullDepth);
}

// returns a number from a text message
function getNumber(str) {
    local pos = 0;
    local numStr = "";
    local digitsp = "1234567890 .,";
    while ((pos < str.len()) && (digitsp.find(str[pos].tochar()) != null)) {
        if (str[pos].tochar() == ".") {
            break;
        } else if ((str[pos].tochar() == ",") || (str[pos].tochar() == " ")) {
        } else {
            numStr = numStr + str[pos].tochar();
        }
        pos++;
    }
    if (numStr == "") numStr = "0";
    return numStr.tointeger();
}

function httpPostToThingSpeak (data) {
    local body = "field1=" + data.distance + "&field2=" + data.delay;
    local request = http.post(thingSpeakUrl, headers, body);
    local response = request.sendsync();
    return response;
}
 
// --- Callback Functions ---
// Function called when device sends new data point
device.on("sendMeasurement", function(measurement) {

  // discontinue if bad data; SMS if alerts on
  local errMsg = "";
  if ((fracFull(measurement.distance) > 1.15) || (fracFull(measurement.distance) < -0.15)) {
      errMsg = "Sensor is returning bad data! Text 'disable' to turn off alerts.";
  } else if (measurement.timeTaken < 1) {
      errMsg = "Sensor is offline! Text 'disable' to turn off alerts.";
  }
  if (errMsg.len() > 1) {
      server.log("Error - " + errMsg);
      if (!errAlertDisable) {
          //send Twilio SMS
          twilio.send(recipientsNumber, errMsg, function(response) {
              server.log(response.statuscode + " - " + response.body);
          });
      }
      return;
  }
  
  // send the data to ThingSpeak
  measurement.delay = time() - measurement.timeTaken;
  local response =  httpPostToThingSpeak(measurement);
  server.log(response.body);

  // next, check if we should reset the alertDisable flag
  if ((alertFlags.find(0) != null) && (fracFull(measurement.distance) >= refillFrac)) {
      server.log("tank refilled! resetting alert flags");
      foreach (i, flag in alertFlags) {
          alertFlags[i] = 1;
      };
  }
  
  // finally, SMS if applicable
  foreach (i, alertLevel in alertLevels) {
      if (alertFlags[i] && (fracFull(measurement.distance) <= alertLevel)) {
          local alertMsg = "Tank Alert! Level is below " + (alertLevel * 100) + "%!";
          server.log(alertMsg);
          //send Twilio SMS
          twilio.send(recipientsNumber, alertMsg, function(response) {
              server.log(response.statuscode + " - " + response.body);
          });
          alertFlags[i] = 0;
          break;
      }
  }
  
  // save the data in case we get an incoming text query
  // Note: we don't save OOB data
  lastMeasurement = measurement;
});

// Function to respond to HTTP (like incoming SMS)
http.onrequest (function(request, response) {
    local path = request.path.tolower();
    if (path == "/twilio" || path == "/twilio/") {
        // Twilio request handler
        local msg = "";
        local smsBody = "";
        
        try {
            local data = http.urldecode(request.body);
            server.log("incoming text from " + data.From);
            // see if it came from whitelist
            if (whitelist.find(data.From) != null) {
                smsBody = data.Body.tolower();
            }
        } catch(ex) {
            msg = "Uh oh, something went horribly wrong: " + ex;
        }
        
        if (smsBody.find("disable") != null) {
            // set alertDisable if applicable
            errAlertDisable = 1;
            msg = "Error Alerts Disabled. Text ‘enable’ to turn them back on.";
        } else if (smsBody.find("enable") != null) {
            // set alertDisable if applicable
            errAlertDisable = 0;
            msg = "Error Alerts enabled. Text ‘disable’ to turn them off.";
        } else if (smsBody.find("level") != null) {
            local levelPct = math.floor(fracFull(lastMeasurement.distance) * 1000.0) / 10;
            local delayMin = (time() - lastMeasurement.timeTaken) / 60;
            msg = "Tank level is at " + levelPct + "%.  Measurement was taken " + delayMin + " minutes ago.";
        } else if (smsBody.find("period=") != null) {
            // extract and send new sampletime to device
            configs.sampleTime = getNumber(smsBody.slice(smsBody.find("period=")+7)) * 60;
            if ((configs.sampleTime >= 60) && (configs.sampleTime <= 86400)) {
                device.send("setConfigs", configs);
                msg = "Sample time updated to " + (configs.sampleTime/60) + " minutes.";
            } else {
                msg = "Invalid sample time.  Use form 'period=nnnn' where n are digits. No spaces, periods or commas.";
            }
        } else if (smsBody.find("help") != null) {
            msg = "’level’ sends current water level.\r‘period=30’ set sensor to 30 minutes. Use any value for 30 from 10 to 1440.\r‘enable’ turn on error alerts.\r‘disable’ turn off error alerts; level alerts stay on.\rOnly 1 command per text.";
        } else {
            msg = "Invalid Command";
        }   
        
        twilio.respond(response, msg);
        
    } else {
        // Default request handler
        response.send(200, "OK")
    }
});

// ---Start it up!---
imp.wakeup(0.1, function() {
    // Wait 1 second for the device to boot before
    // sending it the first message
    device.send("setConfigs", configs);
});

