@IsTest
private class GeotabWebhookListenerTest {

    private static final String DEVICE_ID = 'geotab-webhook-device-1';

    private static String buildPayload(String deviceId, Decimal latitude, Decimal longitude) {
        return JSON.serialize(
            new Map<String, Object>{
                'assetName' => 'Webhook Truck',
                'latitude' => latitude,
                'longitude' => longitude,
                'DeviceId' => deviceId,
                'timestamp' => '2026-06-24T10:00:00.000Z'
            }
        );
    }

    private static RestResponse executeWebhook(String jsonBody, Map<String, String> params) {
        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.requestURI = '/services/apexrest/geotab';
        req.httpMethod = 'POST';

        if (jsonBody != null) {
            req.requestBody = Blob.valueOf(jsonBody);
        }
        if (params != null) {
            for (String key : params.keySet()) {
                req.addParameter(key, params.get(key));
            }
        }

        RestContext.request = req;
        RestContext.response = res;

        Test.startTest();
        GeotabWebhookListener.handleIncomingWebhook();
        Test.stopTest();

        return res;
    }

    @IsTest
    static void testWebhook_SuccessWithBody() {
        String payload = buildPayload(DEVICE_ID, 29.6458, -98.4462);

        RestResponse res = executeWebhook(payload, null);

        Assert.areEqual(200, res.statusCode, 'Expected HTTP 200 on success');
        Assert.isTrue(res.responseBody.toString().contains('success'), 'Expected success response');
    }

    @IsTest
    static void testWebhook_SuccessWithUrlEncodedParams() {
        String payload = buildPayload(DEVICE_ID, 29.6458, -98.4462);
        Map<String, String> params = new Map<String, String>{
            payload => ''
        };

        RestResponse res = executeWebhook(null, params);

        Assert.areEqual(200, res.statusCode, 'Expected HTTP 200 when JSON is passed via params');
        Assert.isTrue(res.responseBody.toString().contains('success'), 'Expected success response');
    }

    @IsTest
    static void testWebhook_NoPayload_Returns400() {
        RestResponse res = executeWebhook(null, null);

        Assert.areEqual(400, res.statusCode, 'Expected HTTP 400 when no payload is provided');
        Assert.isTrue(res.responseBody.toString().contains('No JSON payload found'), 'Expected missing payload message');
    }

    @IsTest
    static void testWebhook_MissingDeviceId_Returns400() {
        String payload = buildPayload('', 29.6458, -98.4462);

        RestResponse res = executeWebhook(payload, null);

        Assert.areEqual(400, res.statusCode, 'Expected HTTP 400 when DeviceId is missing');
        Assert.isTrue(res.responseBody.toString().contains('Missing DeviceId in payload'), 'Expected missing DeviceId message');
    }

    @IsTest
    static void testWebhook_InvalidJson_Returns500() {
        // Malformed JSON triggers JSONException in deserialize and tests the catch block
        String malformedJson = '{ "assetName": "Invalid", "latitude": ';

        RestResponse res = executeWebhook(malformedJson, null);

        Assert.areEqual(500, res.statusCode, 'Expected HTTP 500 on deserialization error');
        Assert.isTrue(res.responseBody.toString().contains('error'), 'Expected error response');
    }
}