@IsTest
private class QuickBooksPOFromQBSyncBatchFixedTest {

    private static final String QB_PO_RESPONSE = '{"QueryResponse":{"PurchaseOrder":[{'
        + '"Id":"1392","DocNumber":"PO-1392","TxnDate":"2026-07-01","DueDate":"2026-07-15",'
        + '"VendorRef":{"value":"V101","name":"Acme Vendor"},'
        + '"CustomerRef":{"value":"C201","name":"Ship Customer"},'
        + '"ShipAddr":{"Line1":"Sandbox Company US 66cc","Line2":"123 Sierra Way",'
        + '"Line3":"San Pablo, CA 87999",'
        + '"City":"San Pablo","CountrySubDivisionCode":"CA","PostalCode":"87999","Country":"USA"},'
        + '"Line":['
        + '{"Id":"1","Amount":100.00,"DetailType":"ItemBasedExpenseLineDetail","Description":"Widget",'
        + '"ItemBasedExpenseLineDetail":{"ItemRef":{"value":"I301"},"Qty":2,"UnitPrice":50,'
        + '"CustomerRef":{"value":"C201","name":"Ship Customer"},'
        + '"ClassRef":{"value":"CL10","name":"Non Installation"}}},'
        + '{"Id":"2","Amount":10.00,"DetailType":"SubTotalLineDetail"}'
        + ']'
        + '}]}}';

    private static final String QB_EMPTY = '{"QueryResponse":{}}';

    @TestSetup
    static void setup() {
        faxa__External_App__c app = new faxa__External_App__c(
            Name = 'QuickBook',
            faxa__Realm_ID__c = '1234567890',
            faxa__Access_Token__c = 'mock_access',
            faxa__Refresh_Token__c = 'mock_refresh',
            faxa__Client_Id__c = 'client',
            faxa__Client_Secret__c = 'secret',
            faxa__Authentication_Status__c = 'Successful'
        );
        insert app;

        insert new List<faxa__Mapping__c>{
            new faxa__Mapping__c(
                faxa__External_App__c = app.Id,
                faxa__FieldAx_Object__c = 'faxa__Purchase_Order__c',
                faxa__FieldAx_Field__c = 'Name',
                faxa__External_App_Field__c = 'DocNumber',
                faxa__Is_Parent_Mapping__c = true,
                faxa__Sequence__c = 1
            ),
            new faxa__Mapping__c(
                faxa__External_App__c = app.Id,
                faxa__FieldAx_Object__c = 'faxa__Purchase_Order__c',
                faxa__FieldAx_Field__c = 'faxa__PO_Date__c',
                faxa__External_App_Field__c = 'TxnDate',
                faxa__Is_Parent_Mapping__c = true,
                faxa__Sequence__c = 2
            ),
            new faxa__Mapping__c(
                faxa__External_App__c = app.Id,
                faxa__FieldAx_Object__c = 'faxa__Purchase_Order__c',
                faxa__FieldAx_Field__c = 'faxa__Shipping_Street__c',
                faxa__External_App_Field__c = 'ShipAddr.Line1',
                faxa__Is_Parent_Mapping__c = true,
                faxa__Sequence__c = 3
            ),
            new faxa__Mapping__c(
                faxa__External_App__c = app.Id,
                faxa__FieldAx_Object__c = 'faxa__Purchase_Order__c',
                faxa__FieldAx_Field__c = 'faxa__Shipping_City__c',
                faxa__External_App_Field__c = 'ShipAddr.City',
                faxa__Is_Parent_Mapping__c = true,
                faxa__Sequence__c = 4
            ),
            new faxa__Mapping__c(
                faxa__External_App__c = app.Id,
                faxa__FieldAx_Object__c = 'faxa__Purchase_Order_Line__c',
                faxa__FieldAx_Field__c = 'faxa__Description__c',
                faxa__External_App_Field__c = 'Line.Description',
                faxa__Is_Parent_Mapping__c = false,
                faxa__Sequence__c = 1
            ),
            new faxa__Mapping__c(
                faxa__External_App__c = app.Id,
                faxa__FieldAx_Object__c = 'faxa__Purchase_Order_Line__c',
                faxa__FieldAx_Field__c = 'faxa__Quantity__c',
                faxa__External_App_Field__c = 'Line.ItemBasedExpenseLineDetail.Qty',
                faxa__Is_Parent_Mapping__c = false,
                faxa__Sequence__c = 2
            ),
            new faxa__Mapping__c(
                faxa__External_App__c = app.Id,
                faxa__FieldAx_Object__c = 'faxa__Purchase_Order_Line__c',
                faxa__FieldAx_Field__c = 'faxa__Quickbooks_Customer_Id__c',
                faxa__External_App_Field__c = 'Line.ItemBasedExpenseLineDetail.CustomerRef.value',
                faxa__Is_Parent_Mapping__c = false,
                faxa__Sequence__c = 3
            ),
            new faxa__Mapping__c(
                faxa__External_App__c = app.Id,
                faxa__FieldAx_Object__c = 'faxa__Purchase_Order_Line__c',
                faxa__FieldAx_Field__c = 'faxa__QuickBooks_Class_Id__c',
                faxa__External_App_Field__c = 'Line.ItemBasedExpenseLineDetail.ClassRef.value',
                faxa__Is_Parent_Mapping__c = false,
                faxa__Sequence__c = 4
            )
        };

        Account vendor = new Account(
            Name = 'Acme Vendor',
            faxa__Account_Type__c = 'Vendor',
            faxa__QuickBooks_Vendor_Id__c = 'V101',
            BillingStreet = '1 St', BillingCity = 'Austin', BillingStateCode = 'TX',
            BillingPostalCode = '78701', BillingCountryCode = 'US',
            ShippingStreet = '1 St', ShippingCity = 'Austin', ShippingStateCode = 'TX',
            ShippingPostalCode = '78701', ShippingCountryCode = 'US'
        );
        Account customer = new Account(
            Name = 'Ship Customer',
            faxa__QuickBooks_Customer_Id__c = 'C201',
            BillingStreet = '2 St', BillingCity = 'Austin', BillingStateCode = 'TX',
            BillingPostalCode = '78701', BillingCountryCode = 'US',
            ShippingStreet = '2 St', ShippingCity = 'Austin', ShippingStateCode = 'TX',
            ShippingPostalCode = '78701', ShippingCountryCode = 'US'
        );
        insert new List<Account>{ vendor, customer };

        // Production VRs require Income + Expense account refs on Product2 (Family=Service).
        faxa__Quick_Book_Account__c expenseAcct = new faxa__Quick_Book_Account__c(
            Name = 'PO Test Expense Account'
        );
        faxa__Quick_Book_Account__c incomeAcct = new faxa__Quick_Book_Account__c(
            Name = 'PO Test Income Account'
        );
        insert new List<faxa__Quick_Book_Account__c>{ expenseAcct, incomeAcct };

        insert new Product2(
            Name = 'Widget Product',
            IsActive = true,
            Family = 'Service',
            faxa__QuickBooks_Item_Id__c = 'I301',
            faxa__ExpensesAccountRef__c = expenseAcct.Id,
            faxa__IncomeAccountRef__c = incomeAcct.Id
        );
        insert new faxa__Class__c(
            Name = 'Non Installation',
            faxa__Class_Id__c = 'CL10',
            faxa__Active__c = true
        );
    }

    private class SuccessMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody(QB_PO_RESPONSE);
            return res;
        }
    }

    private class EmptyMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody(QB_EMPTY);
            return res;
        }
    }

    private class FailMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(500);
            res.setBody('{"error":"server"}');
            return res;
        }
    }

    private class HugeResponseMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            // Body larger than 32k to exercise truncate / STRING_TOO_LONG safe path
            List<String> chunks = new List<String>();
            for (Integer i = 0; i < 400; i++) {
                chunks.add('XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX');
            }
            String pad = String.join(chunks, '');
            res.setBody('{"QueryResponse":{"PurchaseOrder":[{"Id":"9999","DocNumber":"HUGE","TxnDate":"2026-07-01","VendorRef":{"value":"V101"},"Line":[],"Pad":"' + pad + '"}]}}');
            return res;
        }
    }

    @IsTest
    static void testSuccessfulPoSync() {
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        Test.startTest();
        Database.executeBatch(new QuickBooksPOFromQBSyncBatchFixed(false), 1);
        Test.stopTest();

        List<faxa__Purchase_Order__c> pos = [
            SELECT Name, faxa__QuickBooks_PO_Id__c, faxa__Vendor__c, faxa__Ship_To_Customer__c,
                   faxa__PO_Date__c, faxa__Due_Date__c, faxa__Integration_Status__c,
                   faxa__Shipping_Street__c, faxa__Shipping_City__c, faxa__Shipping_State__c,
                   faxa__Shipping_Postal_Code__c, faxa__Shipping_Country__c
            FROM faxa__Purchase_Order__c
            WHERE faxa__QuickBooks_PO_Id__c = '1392'
        ];
        System.assertEquals(1, pos.size(), 'Should insert one PO');
        System.assertEquals('PO-1392', pos[0].Name);
        System.assertNotEquals(null, pos[0].faxa__Vendor__c, 'Vendor lookup from prefetch');
        System.assertEquals(Date.newInstance(2026, 7, 1), pos[0].faxa__PO_Date__c);
        // Before-insert trigger sets Sync_to_QuickBooks; inbound job also stamps Integration_Status
        System.assertEquals('Successful', pos[0].faxa__Integration_Status__c);
        System.assert(
            pos[0].faxa__Shipping_Street__c != null
                && pos[0].faxa__Shipping_Street__c.contains('Sandbox Company US 66cc')
                && pos[0].faxa__Shipping_Street__c.contains('123 Sierra Way')
                && !pos[0].faxa__Shipping_Street__c.contains('San Pablo'),
            'Ship street = Line1+Line2 only; city must be its own field'
        );
        System.assertEquals('San Pablo', pos[0].faxa__Shipping_City__c);
        System.assertEquals('CA', pos[0].faxa__Shipping_State__c);
        System.assertEquals('87999', pos[0].faxa__Shipping_Postal_Code__c);
        System.assertEquals('United States', pos[0].faxa__Shipping_Country__c);

        Account customer = [SELECT Id FROM Account WHERE faxa__QuickBooks_Customer_Id__c = 'C201' LIMIT 1];
        faxa__Class__c cls = [SELECT Id FROM faxa__Class__c WHERE faxa__Class_Id__c = 'CL10' LIMIT 1];
        Product2 prod = [SELECT Id FROM Product2 WHERE faxa__QuickBooks_Item_Id__c = 'I301' LIMIT 1];

        List<faxa__Purchase_Order_Line__c> lines = [
            SELECT faxa__Description__c, faxa__Quantity__c, faxa__Product__c,
                   faxa__Quickbooks_Customer_Id__c, faxa__Customer__c,
                   faxa__QuickBooks_Class_Id__c, faxa__QuickBooks_Class__c
            FROM faxa__Purchase_Order_Line__c
            WHERE faxa__Purchase_Order__c = :pos[0].Id
        ];
        System.assertEquals(1, lines.size(), 'SubTotal line should be skipped');
        System.assertEquals('Widget', lines[0].faxa__Description__c);
        System.assertEquals(2, lines[0].faxa__Quantity__c);
        System.assertEquals(prod.Id, lines[0].faxa__Product__c);
        System.assertEquals('C201', lines[0].faxa__Quickbooks_Customer_Id__c);
        System.assertEquals(customer.Id, lines[0].faxa__Customer__c);
        System.assertEquals('CL10', lines[0].faxa__QuickBooks_Class_Id__c);
        System.assertEquals(cls.Id, lines[0].faxa__QuickBooks_Class__c);
    }

    @IsTest
    static void testUpdatesExistingPo() {
        Account vendor = [SELECT Id FROM Account WHERE faxa__QuickBooks_Vendor_Id__c = 'V101' LIMIT 1];
        faxa__Purchase_Order__c existing = new faxa__Purchase_Order__c(
            Name = 'Old Name',
            faxa__QuickBooks_PO_Id__c = '1392',
            faxa__Vendor__c = vendor.Id,
            faxa__PO_Date__c = Date.today().addDays(-10),
            faxa__Status__c = 'Draft',
            faxa__Sync_to_QuickBooks__c = false
        );
        insert existing;

        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        Test.startTest();
        Database.executeBatch(new QuickBooksPOFromQBSyncBatchFixed(false), 1);
        Test.stopTest();

        faxa__Purchase_Order__c updated = [
            SELECT Name, faxa__PO_Date__c
            FROM faxa__Purchase_Order__c
            WHERE faxa__QuickBooks_PO_Id__c = '1392'
        ];
        System.assertEquals('PO-1392', updated.Name);
        System.assertEquals(Date.newInstance(2026, 7, 1), updated.faxa__PO_Date__c);
        System.assertEquals(
            1,
            [SELECT COUNT() FROM faxa__Purchase_Order__c WHERE faxa__QuickBooks_PO_Id__c = '1392']
        );
    }

    @IsTest
    static void testEmptyAndFailure() {
        Test.setMock(HttpCalloutMock.class, new EmptyMock());
        Test.startTest();
        Database.executeBatch(new QuickBooksPOFromQBSyncBatchFixed(false), 1);
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM faxa__Purchase_Order__c WHERE faxa__QuickBooks_PO_Id__c != null]);
    }

    @IsTest
    static void testApiFailure() {
        Test.setMock(HttpCalloutMock.class, new FailMock());
        Test.startTest();
        Database.executeBatch(new QuickBooksPOFromQBSyncBatchFixed(false), 1);
        Test.stopTest();
        System.assert(
            [SELECT COUNT() FROM faxa__External_App_Request_Log__c WHERE faxa__Status__c LIKE 'Failed%'] >= 1
        );
    }

    @IsTest
    static void testHugeResponseTruncation() {
        Test.setMock(HttpCalloutMock.class, new HugeResponseMock());
        Test.startTest();
        Database.executeBatch(new QuickBooksPOFromQBSyncBatchFixed(false), 1);
        Test.stopTest();
        // Should not throw STRING_TOO_LONG; may or may not create PO depending on parse
        System.assert(![SELECT Id FROM faxa__External_App_Request__c].isEmpty());
    }

    @IsTest
    static void testSchedulableAndConstructors() {
        Test.setMock(HttpCalloutMock.class, new EmptyMock());
        Test.startTest();
        String jobId = System.schedule(
            'QB PO Fixed Test ' + Datetime.now().getTime(),
            '0 0 7 * * ?',
            new QuickBooksPOFromQBSyncBatchFixed()
        );
        Database.executeBatch(new QuickBooksPOFromQBSyncBatchFixed(1, false), 1);
        Database.executeBatch(new QuickBooksPOFromQBSyncBatchFixed(true), 1);
        Test.stopTest();
        System.assertNotEquals(null, jobId);
    }

    @IsTest
    static void testMatchByNameWhenQbIdBlank() {
        Account vendor = [SELECT Id FROM Account WHERE faxa__QuickBooks_Vendor_Id__c = 'V101' LIMIT 1];
        insert new faxa__Purchase_Order__c(
            Name = 'PO-1392',
            faxa__Vendor__c = vendor.Id,
            faxa__PO_Date__c = Date.today(),
            faxa__Status__c = 'Draft',
            faxa__Sync_to_QuickBooks__c = false
        );

        Test.setMock(HttpCalloutMock.class, new SuccessMock());
        Test.startTest();
        Database.executeBatch(new QuickBooksPOFromQBSyncBatchFixed(false), 1);
        Test.stopTest();

        faxa__Purchase_Order__c linked = [
            SELECT faxa__QuickBooks_PO_Id__c FROM faxa__Purchase_Order__c WHERE Name = 'PO-1392' LIMIT 1
        ];
        System.assertEquals('1392', linked.faxa__QuickBooks_PO_Id__c);
    }

    @IsTest
    static void testInvalidJsonAndBlankBody() {
        Test.setMock(HttpCalloutMock.class, new FixedBodyMock('not-json'));
        Test.startTest();
        Database.executeBatch(new QuickBooksPOFromQBSyncBatchFixed(false), 1);
        Test.stopTest();
        System.assert(
            [SELECT COUNT() FROM faxa__External_App_Request_Log__c WHERE faxa__Status__c LIKE 'Failed%'] >= 1
        );

        Test.setMock(HttpCalloutMock.class, new FixedBodyMock(''));
        Database.executeBatch(new QuickBooksPOFromQBSyncBatchFixed(3, false), 1);
    }

    @IsTest
    static void testTokenRefreshRetry() {
        Test.setMock(HttpCalloutMock.class, new TokenThenSuccessMock());
        Test.startTest();
        Database.executeBatch(new QuickBooksPOFromQBSyncBatchFixed(false), 1);
        Test.stopTest();
        System.assert(
            [SELECT COUNT() FROM faxa__Purchase_Order__c WHERE faxa__QuickBooks_PO_Id__c = '1392'] >= 1
        );
    }

    private class FixedBodyMock implements HttpCalloutMock {
        private String body;
        FixedBodyMock(String body) { this.body = body; }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody(body == null ? '' : body);
            return res;
        }
    }

    private class TokenThenSuccessMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            if (req.getEndpoint() != null && req.getEndpoint().contains('oauth2/v1/tokens/bearer')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"new_token","refresh_token":"new_refresh","expires_in":3600}');
                return res;
            }
            if (req.getHeader('Authorization') == 'Bearer mock_access') {
                res.setStatusCode(401);
                res.setBody('{"error":"expired"}');
                return res;
            }
            res.setStatusCode(200);
            res.setBody(QB_PO_RESPONSE);
            return res;
        }
    }
}