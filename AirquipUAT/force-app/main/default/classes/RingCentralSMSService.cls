public class RingCentralSMSService {

    /** Test-only: inject credential when RC_Credential__mdt.Default is not deployed (e.g. in target org during deployment). */
    @TestVisible
    private static CredentialInfo testCredential;

    /** Test-only: returns a CredentialInfo for use when metadata is not present in the org. */
    @TestVisible
    private static CredentialInfo createTestCredential() {
        CredentialInfo c = new CredentialInfo();
        c.clientId = 'test-client-id';
        c.clientSecret = 'test-client-secret';
        c.jwtToken = 'test-jwt-token';
        c.senderNumber = '+15550000000';
        c.serverUrl = 'https://platform.ringcentral.com';
        return c;
    }

    // ─── Inner class for credential data (supports test injection) ───────────
    @TestVisible
    private class CredentialInfo {
        String clientId;
        String clientSecret;
        String jwtToken;
        String senderNumber;
        String serverUrl;
    }

    // ─── Inner class for SMS payload ────────────────────────────────────────
    public class SMSMessage {
        public String toPhone;
        public String messageBody;
        public SMSMessage(String toPhone, String messageBody) {
            this.toPhone      = toPhone;
            this.messageBody  = messageBody;
        }
    }

    // ─── Main entry point ────────────────────────────────────────────────────
    /**
     * Send a single SMS. Safe to call from triggers — uses @future internally.
     */
    public static void sendSMS(String toPhone, String messageBody) {
        if (String.isBlank(toPhone) || String.isBlank(messageBody)) return;
        sendSMSAsync(toPhone, messageBody);
    }

    /**
     * Send multiple SMSes in bulk (e.g., technician + customer on same event).
     */
    public static void sendBulkSMS(List<SMSMessage> messages) {
        for (SMSMessage msg : messages) {
            sendSMS(msg.toPhone, msg.messageBody);
        }
    }

    // ─── Async callout (required from triggers) ──────────────────────────────
    @future(callout=true)
    private static void sendSMSAsync(String toPhone, String messageBody) {
        try {
            CredentialInfo cred = getCredential();
            if (cred == null) {
                logError('RC_Credential__mdt record "Default" not found. Please configure Custom Metadata.');
                return;
            }

            String accessToken = getAccessToken(cred);
            if (String.isBlank(accessToken)) {
                logError('Failed to obtain RingCentral access token.');
                return;
            }

            doSendSMS(accessToken, cred.senderNumber, toPhone, messageBody, cred.serverUrl);

        } catch (Exception e) {
            logError('RingCentralSMSService.sendSMSAsync error: ' + e.getMessage());
        }
    }

    // ─── Step 1: Load credentials from Custom Metadata (or test injection) ───
    private static CredentialInfo getCredential() {
        if (Test.isRunningTest() && testCredential != null) {
            return testCredential;
        }
        List<RC_Credential__mdt> creds = [
            SELECT Client_ID__c, Client_Secret__c, JWT_Token__c,
                   Sender_Number__c, Server_URL__c
            FROM   RC_Credential__mdt
            WHERE  DeveloperName = 'Default'
            LIMIT  1
        ];
        if (creds.isEmpty()) {
            return null;
        }
        RC_Credential__mdt m = creds[0];
        CredentialInfo info = new CredentialInfo();
        info.clientId = m.Client_ID__c;
        info.clientSecret = m.Client_Secret__c;
        info.jwtToken = m.JWT_Token__c;
        info.senderNumber = m.Sender_Number__c;
        info.serverUrl = m.Server_URL__c;
        return info;
    }

    // ─── Step 2: OAuth JWT Grant → access token ──────────────────────────────
    private static String getAccessToken(CredentialInfo cred) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(cred.serverUrl + '/restapi/oauth/token');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/x-www-form-urlencoded');

        // Basic Auth header = Base64(clientId:clientSecret)
        String basicAuth = EncodingUtil.base64Encode(
            Blob.valueOf(cred.clientId + ':' + cred.clientSecret)
        );
        req.setHeader('Authorization', 'Basic ' + basicAuth);
        req.setBody('grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=' + cred.jwtToken);
        req.setTimeout(10000);

        Http http = new Http();
        HttpResponse res = http.send(req);

        if (res.getStatusCode() == 200) {
            Map<String, Object> tokenData = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            return (String) tokenData.get('access_token');
        } else {
            logError('RC Token Error ' + res.getStatusCode() + ': ' + res.getBody());
            return null;
        }
    }

    // ─── Step 3: Send the SMS ─────────────────────────────────────────────────
    private static void doSendSMS(String accessToken, String fromPhone,
                                   String toPhone, String body, String serverUrl) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(serverUrl + '/restapi/v1.0/account/~/extension/~/sms');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Authorization', 'Bearer ' + accessToken);
        req.setTimeout(10000);

        Map<String, Object> payload = new Map<String, Object>{
            'from' => new Map<String, String>{ 'phoneNumber' => fromPhone },
            'to'   => new List<Object>{
                          new Map<String, String>{ 'phoneNumber' => toPhone }
                      },
            'text' => body
        };
        req.setBody(JSON.serialize(payload));

        Http http = new Http();
        HttpResponse res = http.send(req);

        if (res.getStatusCode() != 200) {
            logError('RC SMS Send Error ' + res.getStatusCode() + ' to ' + toPhone + ': ' + res.getBody());
        } else {
            System.debug('✅ RC SMS sent to ' + toPhone + ' | Message: ' + body);
        }
    }

    // ─── Error logging ────────────────────────────────────────────────────────
    private static void logError(String msg) {
        System.debug(LoggingLevel.ERROR, '[RingCentralSMSService] ' + msg);
    }
}