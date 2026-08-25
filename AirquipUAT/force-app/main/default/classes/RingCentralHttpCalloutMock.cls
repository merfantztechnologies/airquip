/**
 * HttpCalloutMock for RingCentral API (OAuth token + SMS).
 * Use Test.setMock(HttpCalloutMock.class, new RingCentralHttpCalloutMock())
 * before triggering code that calls RingCentralSMSService.
 * Optional: new RingCentralHttpCalloutMock(tokenStatusCode, smsStatusCode) for failure scenarios.
 */
@isTest
public class RingCentralHttpCalloutMock implements HttpCalloutMock {

    private Integer tokenStatusCode = 200;
    private Integer smsStatusCode = 200;

    public RingCentralHttpCalloutMock() {}

    public RingCentralHttpCalloutMock(Integer tokenStatusCode, Integer smsStatusCode) {
        this.tokenStatusCode = tokenStatusCode;
        this.smsStatusCode = smsStatusCode;
    }

    public HTTPResponse respond(HTTPRequest req) {
        HttpResponse res = new HttpResponse();
        String endpoint = req.getEndpoint();
        if (endpoint != null && endpoint.contains('/oauth/token')) {
            res.setStatusCode(tokenStatusCode);
            res.setBody(tokenStatusCode == 200
                ? '{"access_token":"test-access-token","token_type":"Bearer","expires_in":3600}'
                : '{"error":"invalid_client"}');
        } else {
            res.setStatusCode(smsStatusCode);
            res.setBody(smsStatusCode == 200
                ? '{"id":"test-sms-id","to":[{"phoneNumber":"+1234567890"}],"from":{"phoneNumber":"+0987654321"}}'
                : '{"error":"SMS send failed"}');
        }
        return res;
    }
}