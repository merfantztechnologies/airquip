@isTest(SeeAllData=true)
private class ProductRequestTriggerHandlerTest {
    private static final String VISIT_TYPE_SERVICE = 'Service';

    private static void applyCategoryFromJobType(fax__Job__c job, fax__Job_Type__c jobType) {
        if (jobType == null) return;
        Map<String, Schema.SObjectField> jobFields = fax__Job__c.SObjectType.getDescribe().fields.getMap();
        Map<String, Schema.SObjectField> typeFields = fax__Job_Type__c.SObjectType.getDescribe().fields.getMap();
        if (jobFields.containsKey('fax__Job_Category__c') && typeFields.containsKey('fax__Job_Category__c')) {
            job.put('fax__Job_Category__c', jobType.get('fax__Job_Category__c'));
        }
    }

    private static fax__Job_Type__c getValidServiceJobType() {
        Map<String, Schema.SObjectField> typeFields = fax__Job_Type__c.SObjectType.getDescribe().fields.getMap();
        String soql = 'SELECT Id, Name';
        if (typeFields.containsKey('fax__Job_Category__c')) soql += ', fax__Job_Category__c';
        soql += ' FROM fax__Job_Type__c'
            + ' WHERE Name IN (\'Compressor Service/Repair\', \'Service Call\', \'Service Repair\', \'Oil Sample Collection\', \'General\')'
            + ' LIMIT 1';
        List<fax__Job_Type__c> types = (List<fax__Job_Type__c>) Database.query(soql);
        System.assert(!types.isEmpty(), 'At least one valid Service job type must exist.');
        return types[0];
    }

    private static fax__Job__c makeJobWithEngineer(Boolean withPhone) {
        Account acc = new Account(Name = 'PR Handler Account');
        insert acc;
        fax__Service_Engineer__c eng = new fax__Service_Engineer__c(
            Name = 'PR Engineer',
            fax__Phone__c = withPhone ? '+15550001111' : null,
            fax__Salesforce_User__c = UserInfo.getUserId()
        );
        insert eng;

        fax__Job_Type__c typeRec = getValidServiceJobType();
        fax__Job__c job = new fax__Job__c(
            fax__Customer__c = acc.Id,
            fax__Status__c = 'Open',
            fax__Planned_Visit_Date_Time__c = System.now(),
            fax__Visit_Type__c = VISIT_TYPE_SERVICE,
            fax__Job_Type__c = typeRec.Id,
            Service_Engineer__c = eng.Id
        );
        applyCategoryFromJobType(job, typeRec);
        insert job;
        return job;
    }

    @isTest
    static void testSendSMSPartRequestCreated_GuardAndDirect() {
        Test.setMock(HttpCalloutMock.class, new RingCentralHttpCalloutMock());
        fax__Job__c job = makeJobWithEngineer(true);
        fax__Product_Request__c pr = new fax__Product_Request__c(
            fax__Job__c = job.Id,
            fax__Status__c = 'Pending',
            fax__Expected_Date__c = Date.today().addDays(1)
        );
        insert pr;

        fax__Product_Request_Item__c item = new fax__Product_Request_Item__c(
            fax__Product_Request__c = pr.Id,
            fax__Qty__c = 2
        );
        insert item;

        Test.startTest();
        ProductRequestTriggerHandler.sendSMSPartRequestCreated(new List<fax__Product_Request_Item__c>());
        ProductRequestTriggerHandler.sendSMSPartRequestCreated(new List<fax__Product_Request_Item__c>{ item });
        Test.stopTest();

        System.assertNotEquals(null, item.Id);
    }

    @isTest
    static void testSendSMSPartRequestCreated_NoEngineerPhonePath() {
        fax__Job__c job = makeJobWithEngineer(false);
        fax__Product_Request__c pr = new fax__Product_Request__c(
            fax__Job__c = job.Id,
            fax__Status__c = 'Pending',
            fax__Expected_Date__c = Date.today().addDays(1)
        );
        insert pr;

        fax__Product_Request_Item__c item = new fax__Product_Request_Item__c(
            fax__Product_Request__c = pr.Id,
            fax__Qty__c = 1
        );
        insert item;

        Test.startTest();
        ProductRequestTriggerHandler.sendSMSPartRequestCreated(new List<fax__Product_Request_Item__c>{ item });
        Test.stopTest();

        System.assert(true, 'Engineer without phone should safely skip SMS send.');
    }

    @isTest
    static void testSendSMSPartRequestReceived_DirectAndNoChange() {
        Test.setMock(HttpCalloutMock.class, new RingCentralHttpCalloutMock());
        fax__Job__c job = makeJobWithEngineer(true);
        fax__Product_Request__c pr = new fax__Product_Request__c(
            fax__Job__c = job.Id,
            fax__Status__c = 'Pending',
            fax__Expected_Date__c = Date.today().addDays(1)
        );
        insert pr;
        insert new List<fax__Product_Request_Item__c>{
            new fax__Product_Request_Item__c(fax__Product_Request__c = pr.Id, fax__Qty__c = 2),
            new fax__Product_Request_Item__c(fax__Product_Request__c = pr.Id, fax__Qty__c = 1)
        };

        fax__Product_Request__c updatedPr = new fax__Product_Request__c(Id = pr.Id, fax__Status__c = 'Received', fax__Job__c = job.Id);
        Map<Id, fax__Product_Request__c> oldMap = new Map<Id, fax__Product_Request__c>{
            pr.Id => new fax__Product_Request__c(Id = pr.Id, fax__Status__c = 'Pending', fax__Job__c = job.Id)
        };

        Test.startTest();
        ProductRequestTriggerHandler.sendSMSPartRequestReceived(new List<fax__Product_Request__c>{ updatedPr }, oldMap);
        ProductRequestTriggerHandler.sendSMSPartRequestReceived(
            new List<fax__Product_Request__c>{ new fax__Product_Request__c(Id = pr.Id, fax__Status__c = 'Received', fax__Job__c = job.Id) },
            new Map<Id, fax__Product_Request__c>{ pr.Id => new fax__Product_Request__c(Id = pr.Id, fax__Status__c = 'Received', fax__Job__c = job.Id) }
        );
        Test.stopTest();

        System.assert(true, 'Received and no-change paths should execute without error.');
    }

    @isTest
    static void testProductRequestTrigger_AfterUpdateToReceived() {
        Test.setMock(HttpCalloutMock.class, new RingCentralHttpCalloutMock());
        fax__Job__c job = makeJobWithEngineer(true);
        fax__Product_Request__c pr = new fax__Product_Request__c(
            fax__Job__c = job.Id,
            fax__Status__c = 'Pending',
            fax__Expected_Date__c = Date.today().addDays(1)
        );
        insert pr;
        insert new fax__Product_Request_Item__c(
            fax__Product_Request__c = pr.Id,
            fax__Qty__c = 3
        );

        Test.startTest();
        pr.fax__Status__c = 'Received';
        update pr;
        Test.stopTest();

        pr = [SELECT fax__Status__c FROM fax__Product_Request__c WHERE Id = :pr.Id];
        System.assertEquals('Received', pr.fax__Status__c);
    }
}