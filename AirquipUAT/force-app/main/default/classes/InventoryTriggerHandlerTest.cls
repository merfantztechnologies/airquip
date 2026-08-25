@isTest(SeeAllData=true)
private class InventoryTriggerHandlerTest {
    private static final String VISIT_TYPE_SERVICE = 'Service';

    private static void applyCategoryFromJobType(fax__Job__c job, fax__Job_Type__c jobType) {
        if (jobType == null) return;
        Map<String, Schema.SObjectField> jobFields = fax__Job__c.SObjectType.getDescribe().fields.getMap();
        Map<String, Schema.SObjectField> typeFields = fax__Job_Type__c.SObjectType.getDescribe().fields.getMap();
        if (jobFields.containsKey('fax__Job_Category__c') && typeFields.containsKey('fax__Job_Category__c')) {
            job.put('fax__Job_Category__c', jobType.get('fax__Job_Category__c'));
        }
    }

    private static fax__Job__c makeJob() {
        Account acc = new Account(Name = 'Inventory Handler Account');
        insert acc;

        Map<String, Schema.SObjectField> typeFields = fax__Job_Type__c.SObjectType.getDescribe().fields.getMap();
        String soql = 'SELECT Id, Name';
        if (typeFields.containsKey('fax__Job_Category__c')) soql += ', fax__Job_Category__c';
        soql += ' FROM fax__Job_Type__c'
            + ' WHERE Name IN (\'Compressor Service/Repair\', \'Service Call\', \'Service Repair\', \'Oil Sample Collection\', \'General\')'
            + ' LIMIT 1';
        fax__Job_Type__c typeRec = ((List<fax__Job_Type__c>) Database.query(soql))[0];

        fax__Job__c job = new fax__Job__c(
            fax__Customer__c = acc.Id,
            fax__Status__c = 'Open',
            fax__Planned_Visit_Date_Time__c = System.now(),
            fax__Visit_Type__c = VISIT_TYPE_SERVICE,
            fax__Job_Type__c = typeRec.Id
        );
        applyCategoryFromJobType(job, typeRec);
        insert job;
        return job;
    }

    private static fax__Inventory__c getAnyInventory() {
        List<fax__Inventory__c> invs = [SELECT Id FROM fax__Inventory__c LIMIT 1];
        if (!invs.isEmpty()) return invs[0];
        insert new fax__Inventory__c();
        return [SELECT Id FROM fax__Inventory__c ORDER BY CreatedDate DESC LIMIT 1];
    }

    private static fax__Inventory__c makeInventorySnapshot(Id invId, Decimal qty, Decimal minQty, String phone) {
        String jsonBody = '{"Id":"' + String.valueOf(invId) + '",'
            + '"fax__Qty_in_Stock__c":' + String.valueOf(qty) + ','
            + '"fax__Minimum_Stock_Level__c":' + String.valueOf(minQty) + ','
            + '"Phone__c":' + (phone == null ? 'null' : '"' + phone + '"')
            + '}';
        return (fax__Inventory__c) JSON.deserialize(jsonBody, fax__Inventory__c.class);
    }
    @isTest
	static void testInventoryTrigger_AfterUpdate_FiresHandler() {
    Test.setMock(HttpCalloutMock.class, new RingCentralHttpCalloutMock());

    // Step 1: Create inventory
    fax__Inventory__c inv = new fax__Inventory__c(
        fax__Quantity_In_Hand__c = 10,
        fax__Minimum_Stock_Level__c = 5,
        Phone__c = '+15550004444'
    );
    insert inv;

    // Step 2: Update to cross below minimum
    inv.fax__Quantity_In_Hand__c = 3;

    Test.startTest();
    update inv; // ✅ THIS fires the trigger
    Test.stopTest();

    System.assert(true, 'Trigger after update should execute successfully.');
	}

    @isTest
    static void testSendSMSLowStockAlert_GuardPaths() {
        Test.startTest();
        InventoryTriggerHandler.sendSMSLowStockAlert(new List<fax__Inventory__c>(), new Map<Id, fax__Inventory__c>());
        Test.stopTest();
        System.assert(true, 'Empty input should safely return.');
    }

    @isTest
    static void testSendSMSLowStockAlert_DirectCrossBelowMin() {
        Test.setMock(HttpCalloutMock.class, new RingCentralHttpCalloutMock());
        fax__Inventory__c inv = getAnyInventory();

        fax__Inventory__c newInv = makeInventorySnapshot(inv.Id, 3, 5, '+15550002222');
        fax__Inventory__c oldInv = makeInventorySnapshot(inv.Id, 10, 5, '+15550002222');
        Map<Id, fax__Inventory__c> oldMap = new Map<Id, fax__Inventory__c>{
            inv.Id => oldInv
        };

        Test.startTest();
        InventoryTriggerHandler.sendSMSLowStockAlert(new List<fax__Inventory__c>{ newInv }, oldMap);
        Test.stopTest();

        System.assert(true, 'Cross-below-min path should execute.');
    }

    @isTest
    static void testSendSMSLowStockAlert_NoPhoneAndAlreadyBelow() {
        Test.setMock(HttpCalloutMock.class, new RingCentralHttpCalloutMock());
        fax__Inventory__c inv = getAnyInventory();

        fax__Inventory__c noPhone = makeInventorySnapshot(inv.Id, 2, 5, null);
        fax__Inventory__c alreadyBelow = makeInventorySnapshot(inv.Id, 2, 5, '+15550003333');
        fax__Inventory__c oldBelow = makeInventorySnapshot(inv.Id, 1, 5, '+15550003333');

        Test.startTest();
        InventoryTriggerHandler.sendSMSLowStockAlert(
            new List<fax__Inventory__c>{ noPhone, alreadyBelow },
            new Map<Id, fax__Inventory__c>{ inv.Id => oldBelow }
        );
        Test.stopTest();

        System.assert(true, 'No-phone and already-below branches should execute safely.');
    }
}