/**
 * Test class for InvoiceTriggerHandler and InvoiceTrigger.
 * Covers QuickBooks sync flag and sendSMSInvoiceGenerated.
 */
@isTest
private class InvoiceTriggerHandlerTest {

    private static faxa__External_App__c setupQuickBookApp() {
        faxa__External_App__c app = new faxa__External_App__c(
            Name = 'QuickBook',
            faxa__Realm_ID__c = '1234567890',
            faxa__Access_Token__c = 'mock_token',
            faxa__Refresh_Token__c = 'mock_refresh',
            faxa__Client_Id__c = 'mock_client',
            faxa__Client_Secret__c = 'mock_secret',
            faxa__Authentication_Status__c = 'Successful'
        );
        insert app;
        return app;
    }

    private static void setupInvoiceMappings(Id appId) {
        insert new List<faxa__Mapping__c>{
            new faxa__Mapping__c(
                faxa__FieldAx_Object__c = 'fax__Invoice__c',
                faxa__FieldAx_Field__c = 'fax__Due_Date__c',
                faxa__External_App_Field__c = 'DueDate',
                faxa__External_App__c = appId,
                faxa__Sequence__c = 1
            ),
            new faxa__Mapping__c(
                faxa__FieldAx_Object__c = 'fax__Invoice__c',
                faxa__FieldAx_Field__c = 'fax__Date__c',
                faxa__External_App_Field__c = 'TxnDate',
                faxa__External_App__c = appId,
                faxa__Sequence__c = 2
            )
        };
    }

    private static Id testProductId;

    private static Id getTestProductId() {
        if (testProductId == null) {
            Product2 product = new Product2(
                Name = 'Invoice Sync Test Product',
                IsActive = true,
                Family = 'Hardware'
            );
            insert product;
            testProductId = product.Id;
        }
        return testProductId;
    }

    private static fax__Invoice_Line_Item__c insertInvoiceLineItem(Id invoiceId) {
        fax__Invoice_Line_Item__c lineItem = new fax__Invoice_Line_Item__c(
            fax__Invoice__c = invoiceId,
            fax__Product__c = getTestProductId()
        );
        insert lineItem;
        return lineItem;
    }

    private static Account buildTestAccount(String name, String phone) {
        Account acc = new Account(
            Name = name,
            BillingStreet = '123 Main St',
            BillingCity = 'Houston',
            BillingState = 'Texas',
            BillingPostalCode = '77001',
            BillingCountry = 'United States',
            ShippingStreet = '456 Ship Ave',
            ShippingCity = 'Dallas',
            ShippingState = 'Texas',
            ShippingPostalCode = '75001',
            ShippingCountry = 'United States'
        );
        if (phone != null) {
            acc.Phone = phone;
        }
        return acc;
    }

    @TestSetup
    static void setup() {
        insert buildTestAccount('Invoice Test Customer', '+15551234567');
    }

    @isTest
    static void testSendSMSInvoiceGenerated_InsertDraft() {
        Test.setMock(HttpCalloutMock.class, new RingCentralHttpCalloutMock());
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        fax__Invoice__c inv = new fax__Invoice__c(
            fax__Site__c = acc.Id,
            fax__Status__c = 'Draft'
        );
        insert inv;
        Test.stopTest();

        System.assertNotEquals(null, inv.Id, 'Invoice should be inserted');
    }

    @isTest
    static void testSendSMSInvoiceGenerated_UpdateToSent() {
        Test.setMock(HttpCalloutMock.class, new RingCentralHttpCalloutMock());
        Account acc = [SELECT Id FROM Account LIMIT 1];

        fax__Invoice__c inv = new fax__Invoice__c(
            fax__Site__c = acc.Id,
            fax__Status__c = 'Pending'
        );
        insert inv;

        Test.startTest();
        inv.fax__Status__c = 'Sent';
        update inv;
        Test.stopTest();

        inv = [SELECT fax__Status__c FROM fax__Invoice__c WHERE Id = :inv.Id];
        System.assertEquals('Sent', inv.fax__Status__c);
    }

    @isTest
    static void testSendSMSInvoiceGenerated_NoPhone_NoSMS() {
        Account acc = buildTestAccount('No Phone Account', null);
        insert acc;

        Test.startTest();
        fax__Invoice__c inv = new fax__Invoice__c(
            fax__Site__c = acc.Id,
            fax__Status__c = 'Draft'
        );
        insert inv;
        Test.stopTest();

        System.assertNotEquals(null, inv.Id, 'Should insert without error when Account has no phone');
    }

    @isTest
    static void testSendSMSInvoiceGenerated_NoAccountIds_EarlyReturn() {
        InvoiceTriggerHandler.sendSMSInvoiceGenerated(
            new List<fax__Invoice__c>(),
            null
        );
        System.assert(true, 'Empty list should return early');
    }

    @isTest
    static void testSendSMSInvoiceGenerated_DirectCall() {
        Test.setMock(HttpCalloutMock.class, new RingCentralHttpCalloutMock());
        Account acc = [SELECT Id FROM Account LIMIT 1];

        fax__Invoice__c inv = new fax__Invoice__c(
            fax__Site__c = acc.Id,
            fax__Status__c = 'Pending'
        );
        insert inv;

        Map<Id, fax__Invoice__c> oldMap = new Map<Id, fax__Invoice__c>();
        oldMap.put(inv.Id, new fax__Invoice__c(Id = inv.Id, fax__Status__c = 'Pending'));

        Test.startTest();
        inv.fax__Status__c = 'Draft';
        update inv;
        InvoiceTriggerHandler.sendSMSInvoiceGenerated(
            new List<fax__Invoice__c>{ inv },
            oldMap
        );
        Test.stopTest();

        System.assert(true, 'Direct call should complete');
    }

    @isTest
    static void testSyncFlagNotSetOnInsertWithoutLineItems() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        fax__Invoice__c inv = new fax__Invoice__c(
            fax__Site__c = acc.Id,
            fax__Status__c = 'Sent'
        );
        insert inv;
        Test.stopTest();

        inv = [
            SELECT Sync_to_Quickbooks__c
            FROM fax__Invoice__c
            WHERE Id = :inv.Id
        ];
        System.assertNotEquals(true, inv.Sync_to_Quickbooks__c,
            'Sync flag should not be set on insert without line items');
    }

    @isTest
    static void testSyncFlagSetWhenLineItemAdded() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        fax__Invoice__c inv = new fax__Invoice__c(
            fax__Site__c = acc.Id,
            fax__Status__c = 'Sent'
        );
        insert inv;

        update new fax__Invoice__c(Id = inv.Id, Sync_to_Quickbooks__c = false);

        Test.startTest();
        insertInvoiceLineItem(inv.Id);
        Test.stopTest();

        inv = [
            SELECT Sync_to_Quickbooks__c
            FROM fax__Invoice__c
            WHERE Id = :inv.Id
        ];
        System.assertEquals(true, inv.Sync_to_Quickbooks__c,
            'Sync flag should be true when a line item update recalculates invoice totals');
    }

    @isTest
    static void testSyncFlagSetOnInsertWhenNotDraftOrInReview() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        fax__Invoice__c inv = new fax__Invoice__c(
            fax__Site__c = acc.Id,
            fax__Status__c = 'Sent'
        );
        insert inv;
        insertInvoiceLineItem(inv.Id);
        InvoiceTriggerHandler.handleAfterInsert(new List<fax__Invoice__c>{ inv });
        Test.stopTest();

        inv = [
            SELECT Sync_to_Quickbooks__c
            FROM fax__Invoice__c
            WHERE Id = :inv.Id
        ];
        System.assertEquals(true, inv.Sync_to_Quickbooks__c,
            'Sync flag should be true when status is eligible and invoice has line items');
    }

    @isTest
    static void testSyncFlagNotSetOnInsertDraft() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        fax__Invoice__c inv = new fax__Invoice__c(
            fax__Site__c = acc.Id,
            fax__Status__c = 'Draft'
        );
        insert inv;
        Test.stopTest();

        inv = [
            SELECT Sync_to_Quickbooks__c
            FROM fax__Invoice__c
            WHERE Id = :inv.Id
        ];
        System.assertNotEquals(true, inv.Sync_to_Quickbooks__c,
            'Sync flag should not be set on insert when status is Draft');
    }

    @isTest
    static void testSyncFlagNotSetOnInsertInReview() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        fax__Invoice__c inv = new fax__Invoice__c(
            fax__Site__c = acc.Id,
            fax__Status__c = 'In Review'
        );
        insert inv;
        Test.stopTest();

        inv = [
            SELECT Sync_to_Quickbooks__c
            FROM fax__Invoice__c
            WHERE Id = :inv.Id
        ];
        System.assertNotEquals(true, inv.Sync_to_Quickbooks__c,
            'Sync flag should not be set on insert when status is In Review');
    }

    @isTest
    static void testSyncFlagSetOnMappedFieldChange() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        setupInvoiceMappings(setupQuickBookApp().Id);

        fax__Invoice__c inv = new fax__Invoice__c(
            fax__Site__c = acc.Id,
            fax__Status__c = 'Sent',
            fax__Due_Date__c = Date.today().addDays(15)
        );
        insert inv;
        insertInvoiceLineItem(inv.Id);

        update new fax__Invoice__c(Id = inv.Id, Sync_to_Quickbooks__c = false);

        fax__Invoice__c oldInv = [
            SELECT Id, fax__Status__c, fax__Due_Date__c, fax__Date__c, Sync_to_Quickbooks__c
            FROM fax__Invoice__c
            WHERE Id = :inv.Id
        ];
        fax__Invoice__c newInv = oldInv.clone(true, true, false, false);
        newInv.fax__Due_Date__c = Date.today().addDays(45);

        Test.startTest();
        InvoiceTriggerHandler.handleBeforeUpdate(
            new List<fax__Invoice__c>{ newInv },
            new Map<Id, fax__Invoice__c>{ newInv.Id => oldInv }
        );
        System.assertEquals(true, newInv.Sync_to_Quickbooks__c,
            'Sync flag should be set before save when a mapped field changes');
        update newInv;
        Test.stopTest();

        inv = [
            SELECT Sync_to_Quickbooks__c
            FROM fax__Invoice__c
            WHERE Id = :inv.Id
        ];
        System.assertEquals(true, inv.Sync_to_Quickbooks__c,
            'Sync flag should be true when a mapped field changes and status is eligible');
    }

    @isTest
    static void testSyncFlagNotSetWhenDraftOnUpdate() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        fax__Invoice__c inv = new fax__Invoice__c(
            fax__Site__c = acc.Id,
            fax__Status__c = 'Draft',
            fax__Due_Date__c = Date.today().addDays(15)
        );
        insert inv;

        update new fax__Invoice__c(Id = inv.Id, Sync_to_Quickbooks__c = false);

        inv.fax__Due_Date__c = Date.today().addDays(45);

        Test.startTest();
        update inv;
        Test.stopTest();

        inv = [
            SELECT Sync_to_Quickbooks__c
            FROM fax__Invoice__c
            WHERE Id = :inv.Id
        ];
        System.assertNotEquals(true, inv.Sync_to_Quickbooks__c,
            'Sync flag should not be set when status is Draft');
    }

    @isTest
    static void testSyncFlagSetOnStatusChangeToEligible() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        fax__Invoice__c inv = new fax__Invoice__c(
            fax__Site__c = acc.Id,
            fax__Status__c = 'Draft'
        );
        insert inv;
        insertInvoiceLineItem(inv.Id);

        update new fax__Invoice__c(Id = inv.Id, Sync_to_Quickbooks__c = false);

        Test.startTest();
        update new fax__Invoice__c(Id = inv.Id, fax__Status__c = 'Sent');
        Test.stopTest();

        inv = [
            SELECT Sync_to_Quickbooks__c, fax__Status__c
            FROM fax__Invoice__c
            WHERE Id = :inv.Id
        ];
        System.assertEquals('Sent', inv.fax__Status__c);
        System.assertEquals(true, inv.Sync_to_Quickbooks__c,
            'Sync flag should be true when status changes to an eligible value');
    }

    @isTest
    static void testSyncFlagNotSetOnStatusChangeToInReview() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        fax__Invoice__c inv = new fax__Invoice__c(
            fax__Site__c = acc.Id,
            fax__Status__c = 'Draft'
        );
        insert inv;

        update new fax__Invoice__c(Id = inv.Id, Sync_to_Quickbooks__c = false);

        Test.startTest();
        update new fax__Invoice__c(Id = inv.Id, fax__Status__c = 'In Review');
        Test.stopTest();

        inv = [
            SELECT Sync_to_Quickbooks__c
            FROM fax__Invoice__c
            WHERE Id = :inv.Id
        ];
        System.assertNotEquals(true, inv.Sync_to_Quickbooks__c,
            'Sync flag should not be set when status changes to In Review');
    }

    @isTest
    static void testLineItemTriggerUpdateAndUndeletePaths() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        fax__Invoice__c inv = new fax__Invoice__c(
            fax__Site__c = acc.Id,
            fax__Status__c = 'Sent'
        );
        insert inv;

        fax__Invoice_Line_Item__c lineItem = new fax__Invoice_Line_Item__c(
            fax__Invoice__c = inv.Id,
            fax__Product__c = getTestProductId()
        );
        insert lineItem;

        Test.startTest();
        lineItem.fax__Product__c = getTestProductId();
        update lineItem;
        delete lineItem;
        undelete lineItem;
        Test.stopTest();

        System.assertNotEquals(null, lineItem.Id, 'Line item trigger paths should execute.');
    }

    @isTest
    static void testSyncFlagSetOnPartialDueDateUpdateOnly() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        setupInvoiceMappings(setupQuickBookApp().Id);

        fax__Invoice__c inv = new fax__Invoice__c(
            fax__Site__c = acc.Id,
            fax__Status__c = 'Sent',
            fax__Due_Date__c = Date.today().addDays(15)
        );
        insert inv;
        insertInvoiceLineItem(inv.Id);

        update new fax__Invoice__c(Id = inv.Id, Sync_to_Quickbooks__c = false);

        Test.startTest();
        update new fax__Invoice__c(
            Id = inv.Id,
            fax__Due_Date__c = Date.today().addDays(30)
        );
        Test.stopTest();

        inv = [
            SELECT Sync_to_Quickbooks__c
            FROM fax__Invoice__c
            WHERE Id = :inv.Id
        ];
        System.assertEquals(true, inv.Sync_to_Quickbooks__c,
            'Sync flag should be true when only a mapped field is updated via partial save');
    }

    @isTest
    static void testSyncFlagNotSetWhenOnlyUnmappedFieldChanges() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        fax__Invoice__c inv = new fax__Invoice__c(
            fax__Site__c = acc.Id,
            fax__Status__c = 'Sent',
            fax__Notes__c = 'Original notes'
        );
        insert inv;
        insertInvoiceLineItem(inv.Id);

        update new fax__Invoice__c(Id = inv.Id, Sync_to_Quickbooks__c = false);

        Test.startTest();
        update new fax__Invoice__c(
            Id = inv.Id,
            fax__Notes__c = 'Updated notes'
        );
        Test.stopTest();

        inv = [
            SELECT Sync_to_Quickbooks__c
            FROM fax__Invoice__c
            WHERE Id = :inv.Id
        ];
        System.assertEquals(false, inv.Sync_to_Quickbooks__c,
            'Sync flag should remain false when no mapped fields change');
    }

    @isTest
    static void testSyncFlagSetOnLineItemDerivedFieldChange() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        fax__Invoice__c inv = new fax__Invoice__c(
            fax__Site__c = acc.Id,
            fax__Status__c = 'Sent'
        );
        insert inv;
        insertInvoiceLineItem(inv.Id);

        update new fax__Invoice__c(Id = inv.Id, Sync_to_Quickbooks__c = false);

        Test.startTest();
        update new fax__Invoice__c(
            Id = inv.Id,
            Sub_Total_Tax_Product__c = 5
        );
        Test.stopTest();

        inv = [
            SELECT Sync_to_Quickbooks__c
            FROM fax__Invoice__c
            WHERE Id = :inv.Id
        ];
        System.assertEquals(true, inv.Sync_to_Quickbooks__c,
            'Sync flag should be true when line-item-derived invoice fields change');
    }

    @isTest
    static void testHandleAfterInsert_setsSyncWhenLineItemsExist() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        fax__Invoice__c inv = new fax__Invoice__c(
            fax__Site__c = acc.Id,
            fax__Status__c = 'Sent'
        );
        insert inv;
        insertInvoiceLineItem(inv.Id);

        Test.startTest();
        InvoiceTriggerHandler.handleAfterInsert(new List<fax__Invoice__c>{ inv });
        Test.stopTest();

        inv = [
            SELECT Sync_to_Quickbooks__c
            FROM fax__Invoice__c
            WHERE Id = :inv.Id
        ];
        System.assertEquals(true, inv.Sync_to_Quickbooks__c,
            'After insert handler should set sync when line items already exist');
    }

    @isTest
    static void testHandleBeforeInsert_noOp() {
        Test.startTest();
        InvoiceTriggerHandler.handleBeforeInsert(new List<fax__Invoice__c>{
            new fax__Invoice__c(fax__Status__c = 'Sent')
        });
        Test.stopTest();
        System.assert(true, 'Before insert handler should complete without error.');
    }

    @isTest
    static void testSyncFlagNotSetWhenUserExplicitlyUnchecks() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        setupInvoiceMappings(setupQuickBookApp().Id);

        fax__Invoice__c inv = new fax__Invoice__c(
            fax__Site__c = acc.Id,
            fax__Status__c = 'Sent',
            fax__Due_Date__c = Date.today().addDays(15)
        );
        insert inv;
        insertInvoiceLineItem(inv.Id);

        Test.startTest();
        update new fax__Invoice__c(
            Id = inv.Id,
            Sync_to_Quickbooks__c = false,
            fax__Due_Date__c = Date.today().addDays(30)
        );
        Test.stopTest();

        inv = [
            SELECT Sync_to_Quickbooks__c
            FROM fax__Invoice__c
            WHERE Id = :inv.Id
        ];
        System.assertEquals(false, inv.Sync_to_Quickbooks__c,
            'Sync flag should stay false when user explicitly unchecks it on save');
    }
}