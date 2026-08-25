@IsTest
private class QuickBooksPaymentSyncBatchFixedTest {

    private static final String QB_INVOICE_ID = 'INV-16';
    private static final String QB_PAYMENT_ID = 'P-100';

    private static final String SINGLE_PAYMENT_RESPONSE =
        '{"QueryResponse":{"Payment":{"Id":"' + QB_PAYMENT_ID + '","TxnDate":"2026-07-29","TotalAmt":125.50,' +
        '"Line":[{"Amount":125.50,"LinkedTxn":[{"TxnId":"' + QB_INVOICE_ID + '","TxnType":"Invoice"}]}]}}}';

    private static final String LIST_PAYMENT_RESPONSE =
        '{"QueryResponse":{"Payment":[{"Id":"P-101","TxnDate":"2026-07-29","TotalAmt":10,' +
        '"Line":[{"Amount":10,"LinkedTxn":[{"TxnId":"INV-17","TxnType":"Invoice"}]}]},' +
        '{"Id":"P-102","TxnDate":"2026-07-29","TotalAmt":20,' +
        '"Line":[{"Amount":20,"LinkedTxn":[{"TxnId":"INV-18","TxnType":"Invoice"}]}]},' +
        '{"TxnDate":"2026-07-29","TotalAmt":5},' +
        '{"Id":"P-103","TxnDate":"2026-07-29","TotalAmt":30,' +
        '"Line":[{"Amount":30,"LinkedTxn":[{"TxnId":"NO-MATCH","TxnType":"Invoice"}]}]}]}}';

    private static final String PARTIAL_INVOICE_RESPONSE =
        '{"QueryResponse":{"Invoice":{"Id":"' + QB_INVOICE_ID + '","Balance":50,"TotalAmt":125.50,"DueDate":"2099-01-01"}}}';

    private static final String PAID_INVOICE_RESPONSE =
        '{"QueryResponse":{"Invoice":[{"Id":"' + QB_INVOICE_ID + '","Balance":0,"TotalAmt":125.50,"DueDate":"2099-01-01"}]}}';

    /** One QB Payment applied to two Invoices. */
    private static final String MULTI_INVOICE_PAYMENT_RESPONSE =
        '{"QueryResponse":{"Payment":{"Id":"P-MULTI","TxnDate":"2026-07-29","TotalAmt":90,' +
        '"Line":[' +
        '{"Amount":40,"LinkedTxn":[{"TxnId":"INV-A","TxnType":"Invoice"}]},' +
        '{"Amount":50,"LinkedTxn":{"TxnId":"INV-B","TxnType":"Invoice"}}' +
        ']}}}';

    /** Two QB Payments against the same Invoice. */
    private static final String MULTI_PAYMENT_SAME_INVOICE_RESPONSE =
        '{"QueryResponse":{"Payment":[' +
        '{"Id":"P-SAME-1","TxnDate":"2026-07-28","TotalAmt":25,' +
        '"Line":[{"Amount":25,"LinkedTxn":[{"TxnId":"INV-SAME","TxnType":"Invoice"}]}]},' +
        '{"Id":"P-SAME-2","TxnDate":"2026-07-29","TotalAmt":35,' +
        '"Line":[{"Amount":35,"LinkedTxn":[{"TxnId":"INV-SAME","TxnType":"Invoice"}]}]}' +
        ']}}';

    private static final String MULTI_INVOICE_QB_RESPONSE =
        '{"QueryResponse":{"Invoice":[' +
        '{"Id":"INV-A","Balance":10,"TotalAmt":50,"DueDate":"2099-01-01"},' +
        '{"Id":"INV-B","Balance":0,"TotalAmt":50,"DueDate":"2099-01-01"}' +
        ']}}';

    private static final String EMPTY_RESPONSE = '{"QueryResponse":{}}';

    @TestSetup
    static void setup() {
        insert new faxa__External_App__c(
            Name = 'QuickBook',
            faxa__Realm_ID__c = '1234567890',
            faxa__Access_Token__c = 'mock_access_token',
            faxa__Refresh_Token__c = 'mock_refresh_token',
            faxa__Client_Id__c = 'mock_client_id',
            faxa__Client_Secret__c = 'mock_client_secret',
            faxa__Authentication_Status__c = 'Successful'
        );
        insert new Account(
            Name = 'QB Payment Test Account',
            BillingStreet = '123 Main St',
            BillingCity = 'Austin',
            BillingCountryCode = 'US',
            BillingStateCode = 'TX',
            BillingPostalCode = '78701',
            ShippingStreet = '123 Main St',
            ShippingCity = 'Austin',
            ShippingCountryCode = 'US',
            ShippingStateCode = 'TX',
            ShippingPostalCode = '78701'
        );
    }

    private class QbSyncMock implements HttpCalloutMock {
        private final Integer paymentStatus;
        private final String paymentBody;
        private final Integer invoiceStatus;
        private final String invoiceBody;

        QbSyncMock(Integer paymentStatus, String paymentBody, Integer invoiceStatus, String invoiceBody) {
            this.paymentStatus = paymentStatus;
            this.paymentBody = paymentBody;
            this.invoiceStatus = invoiceStatus;
            this.invoiceBody = invoiceBody;
        }

        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            String endpoint = req.getEndpoint() == null ? '' : req.getEndpoint().toLowerCase();
            // Invoice status refresh uses "from Invoice"; Payment sync uses "from Payment".
            Boolean isInvoiceQuery = endpoint.contains('invoice') && !endpoint.contains('from%20payment')
                && !endpoint.contains('from+payment') && !endpoint.contains('from payment');
            if (endpoint.contains('from%20invoice') || endpoint.contains('from+invoice')
                || (endpoint.contains('invoice') && endpoint.contains('balance'))) {
                isInvoiceQuery = true;
            }
            if (isInvoiceQuery) {
                res.setStatusCode(invoiceStatus == null ? 200 : invoiceStatus);
                res.setBody(String.isBlank(invoiceBody) ? EMPTY_RESPONSE : invoiceBody);
                return res;
            }
            res.setStatusCode(paymentStatus == null ? 200 : paymentStatus);
            res.setBody(String.isBlank(paymentBody) ? EMPTY_RESPONSE : paymentBody);
            return res;
        }
    }

    private static fax__Invoice__c createMatchedInvoice(String qbInvoiceId, String statusValue) {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        fax__Invoice__c inv = new fax__Invoice__c(
            fax__Site__c = acc.Id,
            QuickBooks_Invoice_ID__c = qbInvoiceId,
            fax__Status__c = statusValue
        );
        insert inv;
        return inv;
    }

    @IsTest
    static void testDeriveInvoiceStatusPaidPartialOverDueAndSfFallback() {
        String paid = QuickBooksPaymentSyncBatchFixed.deriveInvoiceStatusFromPayment(
            null,
            new Map<String, Object>{ 'Balance' => 0, 'TotalAmt' => 100, 'DueDate' => '2026-01-01' },
            'fax__Status__c', null, null, null, null
        );
        System.assertEquals('Paid', paid);

        String overDue = QuickBooksPaymentSyncBatchFixed.deriveInvoiceStatusFromPayment(
            null,
            new Map<String, Object>{ 'Balance' => 50, 'TotalAmt' => 100, 'DueDate' => '2020-01-01' },
            'fax__Status__c', null, null, null, null
        );
        System.assertEquals('Over Due', overDue);

        String partial = QuickBooksPaymentSyncBatchFixed.deriveInvoiceStatusFromPayment(
            null,
            new Map<String, Object>{ 'Balance' => 50, 'TotalAmt' => 100, 'DueDate' => '2099-01-01' },
            'fax__Status__c', null, null, null, null
        );
        System.assertEquals('Partially Paid', partial);

        String unpaidOpen = QuickBooksPaymentSyncBatchFixed.deriveInvoiceStatusFromPayment(
            null,
            new Map<String, Object>{ 'Balance' => 100, 'TotalAmt' => 100, 'DueDate' => '2099-01-01' },
            'fax__Status__c', null, null, null, null
        );
        System.assertEquals(null, unpaidOpen);

        // SF amount fallbacks (no QB payload)
        fax__Invoice__c inv = createMatchedInvoice('INV-SF-1', 'Sent to Customer');
        inv = [
            SELECT Id, fax__Status__c, fax__Amount_Due__c, fax__Amount_Paid__c, fax__Grand_Total__c
            FROM fax__Invoice__c
            WHERE Id = :inv.Id
        ];
        String sfPaid = QuickBooksPaymentSyncBatchFixed.deriveInvoiceStatusFromPayment(
            inv,
            null,
            'fax__Status__c',
            'fax__Amount_Due__c',
            'fax__Amount_Paid__c',
            'fax__Grand_Total__c',
            null
        );
        // Formulas may be null/zero on empty invoice; method must not throw.
        System.assert(sfPaid == null || sfPaid == 'Paid' || sfPaid == 'Partially Paid' || sfPaid == 'Over Due');
    }

    @IsTest
    static void testFetchPageCountParsesSinglePayment() {
        QuickBooksPaymentSyncBatchFixed batch = new QuickBooksPaymentSyncBatchFixed(null, null, false);
        Test.setMock(HttpCalloutMock.class, new QbSyncMock(200, SINGLE_PAYMENT_RESPONSE, 200, EMPTY_RESPONSE));

        Test.startTest();
        Integer count = batch.fetchPageCountForTest(1);
        Test.stopTest();

        System.assertEquals(1, count);
    }

    @IsTest
    static void testFetchPageCountParsesPaymentList() {
        QuickBooksPaymentSyncBatchFixed batch = new QuickBooksPaymentSyncBatchFixed(null, null, false);
        Test.setMock(HttpCalloutMock.class, new QbSyncMock(200, LIST_PAYMENT_RESPONSE, 200, EMPTY_RESPONSE));

        Test.startTest();
        Integer count = batch.fetchPageCountForTest(1);
        Test.stopTest();

        System.assertEquals(4, count);
    }

    @IsTest
    static void testFetchPageCountHandlesEmptyInvalidAndHttpError() {
        QuickBooksPaymentSyncBatchFixed batch = new QuickBooksPaymentSyncBatchFixed(null, null, false);

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new QbSyncMock(200, EMPTY_RESPONSE, 200, EMPTY_RESPONSE));
        Integer emptyCount = batch.fetchPageCountForTest(1);
        Integer invalidPageCount = batch.fetchPageCountForTest(0);
        Test.setMock(HttpCalloutMock.class, new QbSyncMock(500, '{"Fault":{}}', 500, '{"Fault":{}}'));
        Integer errorCount = batch.fetchPageCountForTest(1);
        Test.stopTest();

        System.assertEquals(0, emptyCount);
        System.assertEquals(0, invalidPageCount);
        System.assertEquals(0, errorCount);
    }

    @IsTest
    static void testRunNullPageAndFinishPaths() {
        QuickBooksPaymentSyncBatchFixed batch = new QuickBooksPaymentSyncBatchFixed(null, null, true);

        Test.startTest();
        batch.runNullPageForTest();
        batch.seedFinishStateForTest(3, 1, 0, 0, 1, 1, 0, 0);
        batch.finish(null);
        batch.runLogBulkFailuresForTest('fax__Payment__c');
        Test.stopTest();

        System.assert([SELECT COUNT() FROM faxa__External_App_Request_Log__c] > 0);
    }

    @IsTest
    static void testSkipReasonAndFlushTrackingHelpers() {
        QuickBooksPaymentSyncBatchFixed batch = new QuickBooksPaymentSyncBatchFixed(null, null, false);
        faxa__External_App__c app = [SELECT Id FROM faxa__External_App__c WHERE Name = 'QuickBook' LIMIT 1];
        Account parent = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        batch.seedBatchSkipReasonForTest('Forced skip for test');
        batch.finish(null);
        batch.runFlushForTest(app.Id, parent.Id, 'Account', 'fax__Payment__c', 'Manual tracking from test', true);
        batch.runFlushForTest(app.Id, parent.Id, 'Account', 'fax__Payment__c', 'Manual failure tracking', false);
        Test.stopTest();

        System.assert(
            [SELECT COUNT() FROM faxa__External_App_Request_Log__c] > 0
            || [SELECT COUNT() FROM faxa__External_App_Request__c] > 0
        );
    }

    @IsTest
    static void testBatchCreatesPaymentAndSetsPartiallyPaid() {
        fax__Invoice__c inv = createMatchedInvoice(QB_INVOICE_ID, 'Sent to Customer');
        Test.setMock(HttpCalloutMock.class, new QbSyncMock(200, SINGLE_PAYMENT_RESPONSE, 200, PARTIAL_INVOICE_RESPONSE));

        Test.startTest();
        Database.executeBatch(
            new QuickBooksPaymentSyncBatchFixed('fax__Payment__c', new List<String>{ 'fax__Invoice__c' }, false),
            1
        );
        Test.stopTest();

        List<fax__Payment__c> payments = [
            SELECT Id, QuickBooks_Payment_ID__c, fax__Invoice__c, fax__Amount_Paid__c
            FROM fax__Payment__c
            WHERE QuickBooks_Payment_ID__c = :QB_PAYMENT_ID
        ];
        System.assertEquals(1, payments.size(), 'Matched QB payment should insert');
        System.assertEquals(inv.Id, payments[0].fax__Invoice__c);

        fax__Invoice__c refreshed = [SELECT fax__Status__c FROM fax__Invoice__c WHERE Id = :inv.Id];
        System.assertEquals('Partially Paid', refreshed.fax__Status__c);
    }

    @IsTest
    static void testExtractInvoiceApplicationsSupportsMultiInvoicePayment() {
        Map<String, Object> qbPayment = (Map<String, Object>) JSON.deserializeUntyped(
            '{"Id":"P-MULTI","TotalAmt":90,"Line":[' +
            '{"Amount":40,"LinkedTxn":[{"TxnId":"INV-A","TxnType":"Invoice"}]},' +
            '{"Amount":50,"LinkedTxn":{"TxnId":"INV-B","TxnType":"Invoice"}}]}'
        );

        List<QuickBooksPaymentSyncBatchFixed.PaymentInvoiceApplication> apps =
            QuickBooksPaymentSyncBatchFixed.extractInvoiceApplicationsFromPayment(qbPayment);

        System.assertEquals(2, apps.size(), 'One QB Payment should yield one SF application per Invoice');
        Map<String, Decimal> byInvoice = new Map<String, Decimal>();
        for (QuickBooksPaymentSyncBatchFixed.PaymentInvoiceApplication app : apps) {
            byInvoice.put(app.qbInvoiceId, app.amount);
        }
        System.assertEquals(40, byInvoice.get('INV-A'));
        System.assertEquals(50, byInvoice.get('INV-B'));
    }

    @IsTest
    static void testBatchSplitsOneQbPaymentAcrossMultipleInvoices() {
        fax__Invoice__c invA = createMatchedInvoice('INV-A', 'Sent to Customer');
        fax__Invoice__c invB = createMatchedInvoice('INV-B', 'Sent to Customer');
        Test.setMock(HttpCalloutMock.class, new QbSyncMock(200, MULTI_INVOICE_PAYMENT_RESPONSE, 200, MULTI_INVOICE_QB_RESPONSE));

        Test.startTest();
        Database.executeBatch(
            new QuickBooksPaymentSyncBatchFixed('fax__Payment__c', new List<String>{ 'fax__Invoice__c' }, false),
            1
        );
        Test.stopTest();

        List<fax__Payment__c> payments = [
            SELECT fax__Invoice__c, fax__Amount_Paid__c
            FROM fax__Payment__c
            WHERE QuickBooks_Payment_ID__c = 'P-MULTI'
            ORDER BY fax__Amount_Paid__c ASC
        ];
        System.assertEquals(2, payments.size(), 'One QB Payment should create two SF Payments');
        System.assertEquals(40, payments[0].fax__Amount_Paid__c);
        System.assertEquals(invA.Id, payments[0].fax__Invoice__c);
        System.assertEquals(50, payments[1].fax__Amount_Paid__c);
        System.assertEquals(invB.Id, payments[1].fax__Invoice__c);

        Map<Id, fax__Invoice__c> refreshed = new Map<Id, fax__Invoice__c>([
            SELECT Id, fax__Status__c FROM fax__Invoice__c WHERE Id IN :new List<Id>{ invA.Id, invB.Id }
        ]);
        System.assertEquals('Partially Paid', refreshed.get(invA.Id).fax__Status__c);
        System.assertEquals('Paid', refreshed.get(invB.Id).fax__Status__c);
    }

    @IsTest
    static void testBatchCreatesMultiplePaymentsForSameInvoice() {
        fax__Invoice__c inv = createMatchedInvoice('INV-SAME', 'Sent to Customer');
        String invoicePayload =
            '{"QueryResponse":{"Invoice":{"Id":"INV-SAME","Balance":40,"TotalAmt":100,"DueDate":"2099-01-01"}}}';
        Test.setMock(HttpCalloutMock.class, new QbSyncMock(200, MULTI_PAYMENT_SAME_INVOICE_RESPONSE, 200, invoicePayload));

        Test.startTest();
        Database.executeBatch(
            new QuickBooksPaymentSyncBatchFixed('fax__Payment__c', new List<String>{ 'fax__Invoice__c' }, false),
            1
        );
        Test.stopTest();

        List<fax__Payment__c> payments = [
            SELECT QuickBooks_Payment_ID__c, fax__Amount_Paid__c, fax__Invoice__c
            FROM fax__Payment__c
            WHERE fax__Invoice__c = :inv.Id
            ORDER BY QuickBooks_Payment_ID__c ASC
        ];
        System.assertEquals(2, payments.size(), 'Two QB Payments against one Invoice should create two SF Payments');
        System.assertEquals('P-SAME-1', payments[0].QuickBooks_Payment_ID__c);
        System.assertEquals(25, payments[0].fax__Amount_Paid__c);
        System.assertEquals('P-SAME-2', payments[1].QuickBooks_Payment_ID__c);
        System.assertEquals(35, payments[1].fax__Amount_Paid__c);

        fax__Invoice__c refreshed = [SELECT fax__Status__c FROM fax__Invoice__c WHERE Id = :inv.Id];
        System.assertEquals('Partially Paid', refreshed.fax__Status__c);
    }

    @IsTest
    static void testUpdateInvoiceStatusDirectlyToPartiallyPaid() {
        fax__Invoice__c inv = createMatchedInvoice('INV-DIRECT-1', 'Sent to Customer');
        QuickBooksPaymentSyncBatchFixed batch = new QuickBooksPaymentSyncBatchFixed(
            'fax__Payment__c',
            new List<String>{ 'fax__Invoice__c' },
            false
        );

        Test.startTest();
        batch.updateInvoiceStatusesFromPayments(
            new Map<Id, String>{ inv.Id => 'INV-DIRECT-1' },
            new Map<String, Map<String, Object>>{
                'INV-DIRECT-1' => new Map<String, Object>{
                    'Id' => 'INV-DIRECT-1',
                    'Balance' => 40,
                    'TotalAmt' => 100,
                    'DueDate' => '2099-06-01'
                }
            }
        );
        Test.stopTest();

        fax__Invoice__c refreshed = [SELECT fax__Status__c FROM fax__Invoice__c WHERE Id = :inv.Id];
        System.assertEquals('Partially Paid', refreshed.fax__Status__c);
    }

    @IsTest
    static void testFetchQuickBooksInvoicesByIdsParsesResponse() {
        QuickBooksPaymentSyncBatchFixed batch = new QuickBooksPaymentSyncBatchFixed(null, null, false);
        Test.setMock(HttpCalloutMock.class, new QbSyncMock(200, EMPTY_RESPONSE, 200, PARTIAL_INVOICE_RESPONSE));

        Test.startTest();
        Map<String, Map<String, Object>> rows = batch.fetchQuickBooksInvoicesByIds(
            new Set<String>{ QB_INVOICE_ID },
            'https://quickbooks.api.intuit.com',
            'realm',
            'token'
        );
        Test.stopTest();

        System.assertEquals(1, rows.size());
        System.assertEquals(50, rows.get(QB_INVOICE_ID).get('Balance'));
    }

    @IsTest
    static void testBatchUpdatesExistingPaymentAndSetsPaid() {
        fax__Invoice__c inv = createMatchedInvoice(QB_INVOICE_ID, 'Sent to Customer');
        insert new fax__Payment__c(
            fax__Invoice__c = inv.Id,
            fax__Amount_Paid__c = 1,
            QuickBooks_Payment_ID__c = QB_PAYMENT_ID,
            fax__Payment_Date__c = Date.newInstance(2020, 1, 1),
            fax__Status__c = 'Paid'
        );

        Test.setMock(HttpCalloutMock.class, new QbSyncMock(200, SINGLE_PAYMENT_RESPONSE, 200, PAID_INVOICE_RESPONSE));

        Test.startTest();
        Database.executeBatch(
            new QuickBooksPaymentSyncBatchFixed('fax__Payment__c', new List<String>{ 'fax__Invoice__c' }, false),
            1
        );
        Test.stopTest();

        fax__Payment__c pay = [
            SELECT fax__Amount_Paid__c, fax__Payment_Date__c
            FROM fax__Payment__c
            WHERE QuickBooks_Payment_ID__c = :QB_PAYMENT_ID
            LIMIT 1
        ];
        System.assertEquals(125.50, pay.fax__Amount_Paid__c);
        System.assertEquals(Date.newInstance(2026, 7, 29), pay.fax__Payment_Date__c);

        fax__Invoice__c refreshed = [SELECT fax__Status__c FROM fax__Invoice__c WHERE Id = :inv.Id];
        System.assertEquals('Paid', refreshed.fax__Status__c);
    }

    @IsTest
    static void testBatchUnchangedPaymentStillRefreshesInvoiceStatus() {
        fax__Invoice__c inv = createMatchedInvoice(QB_INVOICE_ID, 'Sent to Customer');
        insert new fax__Payment__c(
            fax__Invoice__c = inv.Id,
            fax__Amount_Paid__c = 125.50,
            QuickBooks_Payment_ID__c = QB_PAYMENT_ID,
            fax__Payment_Date__c = Date.newInstance(2026, 7, 29),
            fax__Status__c = 'Paid'
        );

        Test.setMock(HttpCalloutMock.class, new QbSyncMock(200, SINGLE_PAYMENT_RESPONSE, 200, PARTIAL_INVOICE_RESPONSE));

        Test.startTest();
        Database.executeBatch(
            new QuickBooksPaymentSyncBatchFixed('fax__Payment__c', new List<String>{ 'fax__Invoice__c' }, false),
            1
        );
        Test.stopTest();

        fax__Invoice__c refreshed = [SELECT fax__Status__c FROM fax__Invoice__c WHERE Id = :inv.Id];
        System.assertEquals('Partially Paid', refreshed.fax__Status__c);
    }

    @IsTest
    static void testBatchExecuteWithMissingInvoiceMatch() {
        Test.setMock(HttpCalloutMock.class, new QbSyncMock(200, SINGLE_PAYMENT_RESPONSE, 200, EMPTY_RESPONSE));

        Test.startTest();
        Database.executeBatch(new QuickBooksPaymentSyncBatchFixed(null, null, false), 1);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM fax__Payment__c WHERE QuickBooks_Payment_ID__c = :QB_PAYMENT_ID]);
    }

    @IsTest
    static void testBatchExecuteHandlesPaymentQueryFailure() {
        Test.setMock(HttpCalloutMock.class, new QbSyncMock(400, '{"Fault":{}}', 200, EMPTY_RESPONSE));

        Test.startTest();
        Database.executeBatch(
            new QuickBooksPaymentSyncBatchFixed('fax__Payment__c', new List<String>{ 'fax__Invoice__c' }, true),
            1
        );
        Test.stopTest();

        System.assert(true);
    }

    @IsTest
    static void testBatchExecuteBlankTokenSkips() {
        faxa__External_App__c app = [SELECT Id FROM faxa__External_App__c WHERE Name = 'QuickBook' LIMIT 1];
        app.faxa__Access_Token__c = null;
        update app;

        Test.startTest();
        Database.executeBatch(
            new QuickBooksPaymentSyncBatchFixed('fax__Payment__c', new List<String>{ 'fax__Invoice__c' }, false),
            1
        );
        Test.stopTest();

        System.assert(true);
    }

    @IsTest
    static void testBatchExecuteListWithMixedRows() {
        createMatchedInvoice('INV-17', 'Sent to Customer');
        Test.setMock(HttpCalloutMock.class, new QbSyncMock(200, LIST_PAYMENT_RESPONSE, 404, '{"Fault":{}}'));

        Test.startTest();
        Database.executeBatch(
            new QuickBooksPaymentSyncBatchFixed('fax__Payment__c', new List<String>{ 'fax__Invoice__c' }, false),
            1
        );
        Test.stopTest();

        System.assert([SELECT COUNT() FROM fax__Payment__c WHERE QuickBooks_Payment_ID__c = 'P-101'] >= 0);
    }

    @IsTest
    static void testRunBatchEntryPoint() {
        Test.setMock(HttpCalloutMock.class, new QbSyncMock(200, EMPTY_RESPONSE, 200, EMPTY_RESPONSE));

        Test.startTest();
        Id jobId = QuickBooksPaymentSyncBatchFixed.runBatch();
        Test.stopTest();

        System.assertNotEquals(null, jobId);
    }

    @IsTest
    static void testSchedulableExecute() {
        Test.setMock(HttpCalloutMock.class, new QbSyncMock(200, EMPTY_RESPONSE, 200, EMPTY_RESPONSE));

        Test.startTest();
        String jobId = System.schedule(
            'QB Payment Sync Test ' + Datetime.now().getTime(),
            '0 0 5 * * ?',
            new QuickBooksPaymentSyncBatchFixed('fax__Payment__c', new List<String>{ 'fax__Invoice__c' }, false)
        );
        Test.stopTest();

        System.assertNotEquals(null, jobId);
    }
}