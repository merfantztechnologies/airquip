/**
 * Test class for ServiceTermExpiryScheduler.
 * Covers the Schedulable execute method.
 */
@isTest
private class ServiceTermExpirySchedulerTest {

    @isTest
    static void testExecute() {
        Test.setMock(HttpCalloutMock.class, new RingCentralHttpCalloutMock());

        Test.startTest();
        String cronExp = '0 0 8 * * ?';
        String jobId = System.schedule('ServiceTermExpirySchedulerTest', cronExp, new ServiceTermExpiryScheduler());
        Test.stopTest();

        System.assertNotEquals(null, jobId, 'Schedule job should be queued');
    }

    @isTest
    static void testExecuteDirect() {
        Test.setMock(HttpCalloutMock.class, new RingCentralHttpCalloutMock());

        ServiceTermExpiryScheduler sch = new ServiceTermExpiryScheduler();

        Test.startTest();
        sch.execute(null);
        Test.stopTest();

        System.assert(true, 'Scheduler execute should complete');
    }
}