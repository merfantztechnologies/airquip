@RestResource(urlMapping='/geotab')
global without sharing class GeotabWebhookListener {
    // Wrapper class to map the incoming JSON from Geotab
    public class GeotabPayload {
        public String assetName;
        public Decimal latitude;
        public Decimal longitude;
        public String DeviceId;
        public String timestamp;
    }

    @HttpPost
    global static void handleIncomingWebhook() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        
        try {
            String jsonString = '';
            
            // 1. EXTRACT JSON: Check body first, then fallback to parameters
            if (req.requestBody != null && String.isNotBlank(req.requestBody.toString())) {
                jsonString = req.requestBody.toString();
            } else if (req.params != null && !req.params.isEmpty()) {
                // Because of x-www-form-urlencoded, Salesforce puts the JSON as a map key
                for (String key : req.params.keySet()) {
                    if (key.trim().startsWith('{')) {
                        jsonString = key;
                        break; // We found the JSON, exit the loop
                    }
                }
            }

            // If we still have no JSON, exit early
            if (String.isBlank(jsonString)) {
                res.statusCode = 400;
                res.responseBody = Blob.valueOf('{"status": "error", "message": "No JSON payload found"}');
                return;
            }

            // 2. Parse the JSON
            GeotabPayload payload = (GeotabPayload) JSON.deserialize(jsonString, GeotabPayload.class);
            
            // 3. Validate payload has the required Device ID
            if (String.isBlank(payload.DeviceId)) {
                res.statusCode = 400;
                res.responseBody = Blob.valueOf('{"status": "error", "message": "Missing DeviceId in payload"}');
                return;
            }
            
            System.debug('Device----' + payload.DeviceId);
          

            // 8. Invoke the autolaunched flow
            Map<String, Object> flowInputs = new Map<String, Object>();
            flowInputs.put('DeviceId', payload.DeviceId);
            flowInputs.put('Longtitude', String.valueOf(payload.longitude)); 
            flowInputs.put('Latitude', String.valueOf(payload.latitude));
            
            Flow.Interview.UpdateGeoLocationFronGeoTab geoFlow = 
                new Flow.Interview.UpdateGeoLocationFronGeoTab(flowInputs);
            geoFlow.start();
            
            // 9. Return success back to Geotab
            res.statusCode = 200;
            res.responseBody = Blob.valueOf('{"status": "success", "recordId": ""}');

        } catch (Exception e) {
            System.debug('Geotab Webhook Error: ' + e.getMessage());
            res.statusCode = 500;
            res.responseBody = Blob.valueOf('{"status": "error", "message": "' + e.getMessage() + '"}');
        }
    }
}