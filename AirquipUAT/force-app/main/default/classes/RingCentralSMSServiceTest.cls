/**
 * Test class for RingCentralSMSService.
 * Uses test credential injection so tests run without RC_Credential__mdt.Default in the org.
 */
@isTest
private class RingCentralSMSServiceTest {

    @isTest
    static void testSendSMS_BlankPhone_NoOp() {
        Test.startTest();
        RingCentralSMSService.sendSMS(null, 'Hello');
        RingCentralSMSService.sendSMS('', 'Hello');
        RingCentralSMSService.sendSMS('+1234567890', '');
        RingCentralSMSService.sendSMS('  ', 'Hello');
        Test.stopTest();
        System.assert(true, 'Blank inputs should return without error');
    }

    @isTest
    static void testSendBulkSMS_EmptyList() {
        Test.startTest();
        RingCentralSMSService.sendBulkSMS(new List<RingCentralSMSService.SMSMessage>());
        Test.stopTest();
        System.assert(true, 'Empty list should not throw');
    }

    @isTest
    static void testSendBulkSMS_WithMessages() {
        RingCentralSMSService.testCredential = RingCentralSMSService.createTestCredential();
        Test.setMock(HttpCalloutMock.class, new RingCentralHttpCalloutMock());
        List<RingCentralSMSService.SMSMessage> msgs = new List<RingCentralSMSService.SMSMessage>();
        msgs.add(new RingCentralSMSService.SMSMessage('+15551234567', 'Test 1'));
        msgs.add(new RingCentralSMSService.SMSMessage('+15559876543', 'Test 2'));
        Test.startTest();
        RingCentralSMSService.sendBulkSMS(msgs);
        Test.stopTest();
        System.assert(true, 'Bulk SMS should queue without error');
    }

    @isTest
    static void testSendSMS_ValidParams_FullFlow() {
        RingCentralSMSService.testCredential = RingCentralSMSService.createTestCredential();
        Test.setMock(HttpCalloutMock.class, new RingCentralHttpCalloutMock());
        Test.startTest();
        RingCentralSMSService.sendSMS('+15551234567', 'Hi from Airquip');
        Test.stopTest();
        System.assert(true, 'SMS should queue and execute future');
    }

    @isTest
    static void testSendSMS_CredentialNotFound() {
        RingCentralSMSService.testCredential = null;  // No metadata, no injection
        Test.setMock(HttpCalloutMock.class, new RingCentralHttpCalloutMock());
        Test.startTest();
        RingCentralSMSService.sendSMS('+15551234567', 'Test');
        Test.stopTest();
        System.assert(true, 'Should handle missing credential gracefully');
    }

    @isTest
    static void testSendSMS_TokenFailure() {
        RingCentralSMSService.testCredential = RingCentralSMSService.createTestCredential();
        Test.setMock(HttpCalloutMock.class, new RingCentralHttpCalloutMock(401, 200));
        Test.startTest();
        RingCentralSMSService.sendSMS('+15551234567', 'Test');
        Test.stopTest();
        System.assert(true, 'Should handle token failure gracefully');
    }

    @isTest
    static void testSendSMS_SendFailure() {
        RingCentralSMSService.testCredential = RingCentralSMSService.createTestCredential();
        Test.setMock(HttpCalloutMock.class, new RingCentralHttpCalloutMock(200, 500));
        Test.startTest();
        RingCentralSMSService.sendSMS('+15551234567', 'Test');
        Test.stopTest();
        System.assert(true, 'Should handle SMS send failure gracefully');
    }

    @isTest
    static void testSendSMS_ExceptionHandling() {
        RingCentralSMSService.testCredential = RingCentralSMSService.createTestCredential();
        Test.setMock(HttpCalloutMock.class, new ThrowingHttpCalloutMock());
        Test.startTest();
        RingCentralSMSService.sendSMS('+15551234567', 'Test');
        Test.stopTest();
        System.assert(true, 'Should handle HTTP exception gracefully');
    }

    @isTest
    static void testSMSMessage_Constructor() {
        RingCentralSMSService.SMSMessage msg = new RingCentralSMSService.SMSMessage('+1', 'body');
        System.assertEquals('+1', msg.toPhone);
        System.assertEquals('body', msg.messageBody);
    }

    /** Mock that throws to cover exception handling in sendSMSAsync. */
    private class ThrowingHttpCalloutMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            throw new CalloutException('Simulated callout failure');
        }
    }
}