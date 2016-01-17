// NOTE all configuration parameters are in agent.

// ---Variables---
configs <- {                // overwritten upon startup
    "sampleTime" : 900      // seconds between sending data to agent
};                          

stringBuffer <- "";     // used to store data from sensor

latestMeasurement <- {  // used to send data to agent
    "distance" : 1000,
    "delay" : 0,
    "timeTaken" : 1452039011
};
timerHandle <- null;         // used to ensure we don't get timer overlaps
local digits = "1234567890";

// ---Callback Functions---
function maxbotixData() {
    // Read the UART for data sent by Maxbotix sensor.
    //server.log("UART read");
    local b = maxbotix.read();
    while (b != -1) {
        // As long as UART read value is not -1, we're getting data
        if (b.tochar() == "R") stringBuffer = "";
        if (digits.find(b.tochar()) != null) stringBuffer += b.tochar();
        if (b.tochar() == "\r") {
            latestMeasurement.distance = stringBuffer.tointeger();
            latestMeasurement.timeTaken = time();
        }
        
        b = maxbotix.read();
    }
}

function sendData () {
    if (timerHandle) imp.cancelwakeup(timerHandle);
    timerHandle = imp.wakeup(configs.sampleTime, sendData);

    agent.send("sendMeasurement", latestMeasurement);
    //server.log("sent measurement to agent: " + latestMeasurement.distance + " with time " + latestMeasurement.timeTaken)

    latestMeasurement.timeTaken = 0;  // reset the measurement so the agent knows if it's getting stale data
}

agent.on("setConfigs", function(data) {
    
    if ((data.sampleTime >= 10) && (data.sampleTime <= 86400)) {
        configs.sampleTime = data.sampleTime;
    }
    
    sendData();
});

// ---Hardward Config---
// Alias UART to which Maxbotix distance is connected and configure UART
maxbotix <- hardware.uart1289;
maxbotix.configure(9600, 8, PARITY_NONE, 1, NO_CTSRTS + NO_TX, maxbotixData);

sendData();
