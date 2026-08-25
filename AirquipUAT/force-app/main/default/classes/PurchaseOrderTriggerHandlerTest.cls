@IsTest
private class PurchaseOrderTriggerHandlerTest {

    private static Account buildVendorAccount(String name) {
        return new Account(
            Name = name,
            faxa__Account_Type__c = 'Vendor',
            faxa__QuickBooks_Vendor_Id__c = 'QB-VENDOR-001',
            BillingStreet = '123 Main St',
            BillingCity = 'Houston',
            BillingState = 'Texas',
            BillingPostalCode = '77001',
            BillingCountry = 'United States',
            ShippingStreet = '123 Ship St',
            ShippingCity = 'Houston',
            ShippingState = 'Texas',
            ShippingPostalCode = '77001',
            ShippingCountry = 'United States'
        );
    }

    private static void setupPurchaseOrderMappings() {
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

        insert new List<faxa__Mapping__c>{
            new faxa__Mapping__c(
                faxa__FieldAx_Object__c = 'faxa__Purchase_Order__c',
                faxa__FieldAx_Field__c = 'faxa__PO_Date__c',
                faxa__External_App_Field__c = 'TxnDate',
                faxa__External_App__c = app.Id,
                faxa__Sequence__c = 1
            ),
            new faxa__Mapping__c(
                faxa__FieldAx_Object__c = 'faxa__Purchase_Order__c',
                faxa__FieldAx_Field__c = 'faxa__Shipping_City__c',
                faxa__External_App_Field__c = 'ShipCity',
                faxa__External_App__c = app.Id,
                faxa__Sequence__c = 2
            )
        };
    }

    @IsTest
    static void testSyncFlagSetOnInsert() {
        faxa__Purchase_Order__c po = new faxa__Purchase_Order__c(
            faxa__PO_Date__c = Date.today(),
            faxa__Status__c = 'Draft'
        );

        Test.startTest();
        PurchaseOrderTriggerHandler.handleBeforeInsert(new List<faxa__Purchase_Order__c>{ po });
        Test.stopTest();

        System.assertEquals(true, po.faxa__Sync_to_QuickBooks__c,
            'Sync flag should be true on create');
    }

    @IsTest
    static void testSyncFlagSetOnMappedFieldChange() {
        setupPurchaseOrderMappings();

        Id poId = faxa__Purchase_Order__c.SObjectType.getDescribe().getKeyPrefix() + '000000000001';
        faxa__Purchase_Order__c oldPo = new faxa__Purchase_Order__c(
            Id = poId,
            faxa__PO_Date__c = Date.today(),
            faxa__Sync_to_QuickBooks__c = false
        );
        faxa__Purchase_Order__c newPo = oldPo.clone(true, true, false, false);
        newPo.faxa__PO_Date__c = Date.today().addDays(1);

        Test.startTest();
        PurchaseOrderTriggerHandler.handleBeforeUpdate(
            new List<faxa__Purchase_Order__c>{ newPo },
            new Map<Id, faxa__Purchase_Order__c>{ poId => oldPo }
        );
        Test.stopTest();

        System.assertEquals(true, newPo.faxa__Sync_to_QuickBooks__c,
            'Sync flag should be true when a mapped field changes');
    }

    @IsTest
    static void testSyncFlagNotSetWhenNoMappedFieldChanges() {
        setupPurchaseOrderMappings();

        Id poId = faxa__Purchase_Order__c.SObjectType.getDescribe().getKeyPrefix() + '000000000002';
        faxa__Purchase_Order__c oldPo = new faxa__Purchase_Order__c(
            Id = poId,
            faxa__PO_Date__c = Date.today(),
            faxa__Permit_No__c = 'OLD-PERMIT',
            faxa__Sync_to_QuickBooks__c = false
        );
        faxa__Purchase_Order__c newPo = oldPo.clone(true, true, false, false);
        newPo.faxa__Permit_No__c = 'NEW-PERMIT';

        Test.startTest();
        PurchaseOrderTriggerHandler.handleBeforeUpdate(
            new List<faxa__Purchase_Order__c>{ newPo },
            new Map<Id, faxa__Purchase_Order__c>{ poId => oldPo }
        );
        Test.stopTest();

        System.assertEquals(false, newPo.faxa__Sync_to_QuickBooks__c,
            'Sync flag should remain false when no mapped field changes');
    }

    @IsTest
    static void testSyncFlagNotOverriddenWhenExplicitlyChanged() {
        setupPurchaseOrderMappings();

        Id poId = faxa__Purchase_Order__c.SObjectType.getDescribe().getKeyPrefix() + '000000000003';
        faxa__Purchase_Order__c oldPo = new faxa__Purchase_Order__c(
            Id = poId,
            faxa__PO_Date__c = Date.today(),
            faxa__Sync_to_QuickBooks__c = true
        );
        faxa__Purchase_Order__c newPo = oldPo.clone(true, true, false, false);
        newPo.faxa__PO_Date__c = Date.today().addDays(1);
        newPo.faxa__Sync_to_QuickBooks__c = false;

        Test.startTest();
        PurchaseOrderTriggerHandler.handleBeforeUpdate(
            new List<faxa__Purchase_Order__c>{ newPo },
            new Map<Id, faxa__Purchase_Order__c>{ poId => oldPo }
        );
        Test.stopTest();

        System.assertEquals(false, newPo.faxa__Sync_to_QuickBooks__c,
            'Sync flag should respect an explicit user change');
    }

    @IsTest
    static void testTriggerSetsSyncFlagOnCreateAndUpdate() {
        setupPurchaseOrderMappings();
        Account vendor = buildVendorAccount('Test Vendor PO Trigger');
        insert vendor;

        Test.startTest();
        faxa__Purchase_Order__c po = new faxa__Purchase_Order__c(
            faxa__Vendor__c = vendor.Id,
            faxa__PO_Date__c = Date.today(),
            faxa__Status__c = 'Draft'
        );
        insert po;

        po = [
            SELECT Id, faxa__Sync_to_QuickBooks__c
            FROM faxa__Purchase_Order__c
            WHERE Id = :po.Id
        ];
        System.assertEquals(true, po.faxa__Sync_to_QuickBooks__c,
            'Trigger should set sync flag on create');

        update new faxa__Purchase_Order__c(
            Id = po.Id,
            faxa__Sync_to_QuickBooks__c = false
        );

        update new faxa__Purchase_Order__c(
            Id = po.Id,
            faxa__PO_Date__c = Date.today().addDays(1)
        );
        Test.stopTest();

        po = [
            SELECT faxa__Sync_to_QuickBooks__c
            FROM faxa__Purchase_Order__c
            WHERE Id = :po.Id
        ];
        System.assertEquals(true, po.faxa__Sync_to_QuickBooks__c,
            'Trigger should set sync flag when a mapped field changes');
    }
}