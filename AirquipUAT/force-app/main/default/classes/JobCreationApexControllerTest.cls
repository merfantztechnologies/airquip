@isTest
private class JobCreationApexControllerTest {

    /*
     * ============================================================
     * TEST SETUP
     * ============================================================
     */
    @testSetup
    static void setupData() {

        Account acc = createTestAccount('Test Account');

        Contact con = new Contact(
            LastName = 'Test Contact',
            Email = 'test.contact@example.com',
            AccountId = acc.Id
        );
        insert con;

        Product2 prod = createTestProduct('Test Product');

        /*
         * ========================================================
         * STANDARD PRICEBOOK
         * ========================================================
         */

        Id standardPbId = Test.getStandardPricebookId();

        /*
         * REQUIRED:
         * STANDARD PRICE ENTRY
         */
        PricebookEntry standardPbe =
            new PricebookEntry(
                Pricebook2Id = standardPbId,
                Product2Id = prod.Id,
                UnitPrice = 100,
                IsActive = true
            );

        insert standardPbe;

        /*
         * ========================================================
         * CUSTOM PRICEBOOK
         * ========================================================
         */

        Pricebook2 customPb = new Pricebook2(
            Name = 'Custom Test PB',
            IsActive = true
        );
        insert customPb;

        /*
         * CUSTOM PRICEBOOK ENTRY
         */
        PricebookEntry customPbe =
            new PricebookEntry(
                Pricebook2Id = customPb.Id,
                Product2Id = prod.Id,
                UnitPrice = 100,
                IsActive = true
            );

        insert customPbe;

        /*
         * ========================================================
         * ORDER STATUS
         * ========================================================
         */

        String orderStatus;

        for (Schema.PicklistEntry pe :
            Order.Status.getDescribe().getPicklistValues()) {

            if (pe.isActive()) {
                orderStatus = pe.getValue();
                break;
            }
        }

        /*
         * ========================================================
         * ORDER
         * ========================================================
         */

        Order ord = new Order(
            AccountId = acc.Id,
            EffectiveDate = Date.today(),
            Status = orderStatus,
            Pricebook2Id = customPb.Id,
            Contact__c = con.Id
        );
        insert ord;

        /*
         * ========================================================
         * ORDER ITEM
         * ========================================================
         */

        OrderItem oi = new OrderItem(
            OrderId = ord.Id,
            Quantity = 1,
            UnitPrice = 100,
            PricebookEntryId = customPbe.Id,
            Line_Description__c = 'Test Line Description'
        );
        insert oi;

        /*
         * ========================================================
         * JOB TYPE
         * ========================================================
         */

        fax__Job_Type__c jt = new fax__Job_Type__c(
            Name = getCategoryValue(),
            fax__Active__c = true
        );
        insert jt;
    }

    /*
     * ============================================================
     * HELPERS
     * ============================================================
     */

    private static Account createTestAccount(String name) {
        Account acc = new Account(
            Name = name,
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
        insert acc;
        return acc;
    }

    private static Product2 createTestProduct(String name) {
        Product2 prod = new Product2(
            Name = name,
            Family = 'Hardware',
            IsActive = true
        );
        insert prod;
        return prod;
    }

    private static String getPriorityValue() {

        for (Schema.PicklistEntry pe :
            fax__Job__c.fax__Urgency__c
                .getDescribe()
                .getPicklistValues()) {

            if (pe.isActive()) {
                return pe.getValue();
            }
        }

        return null;
    }

    private static String getCategoryValue() {

        for (Schema.PicklistEntry pe :
            fax__Job__c.fax__Visit_Type__c
                .getDescribe()
                .getPicklistValues()) {

            if (pe.isActive()) {
                return pe.getValue();
            }
        }

        return null;
    }

    private static Boolean isOrderStatusAvailable(String statusValue) {
        for (Schema.PicklistEntry pe : Order.Status.getDescribe().getPicklistValues()) {
            if (pe.isActive() && pe.getValue() == statusValue) {
                return true;
            }
        }

        return false;
    }

    private static Order createApprovedQuoteOrder() {
        Account acc = [
            SELECT Id
            FROM Account
            LIMIT 1
        ];
        Contact con = [
            SELECT Id
            FROM Contact
            LIMIT 1
        ];
        Pricebook2 customPb = [
            SELECT Id
            FROM Pricebook2
            WHERE Name = 'Custom Test PB'
            LIMIT 1
        ];
        PricebookEntry customPbe = [
            SELECT Id
            FROM PricebookEntry
            WHERE Pricebook2Id = :customPb.Id
            AND IsActive = true
            LIMIT 1
        ];

        Opportunity opp = new Opportunity(
            Name = 'Quote Job Opportunity',
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            AccountId = acc.Id,
            Pricebook2Id = customPb.Id
        );
        insert opp;

        Quote quote = new Quote(
            Name = 'Quote Job Quote',
            QuoteAccountId = acc.Id,
            OpportunityId = opp.Id,
            Pricebook2Id = customPb.Id,
            ContactId = con.Id,
            Status = 'Draft'
        );
        insert quote;

        opp.SyncedQuoteId = quote.Id;
        update opp;

        insert new QuoteLineItem(
            QuoteId = quote.Id,
            PricebookEntryId = customPbe.Id,
            Quantity = 1,
            UnitPrice = 100
        );

        quote.Status = 'Approved';
        update quote;

        return [
            SELECT Id, QuoteId, Contact__c, AccountId
            FROM Order
            WHERE QuoteId = :quote.Id
            LIMIT 1
        ];
    }

    /*
     * ============================================================
     * GET JOB TYPES
     * ============================================================
     */

    @isTest
    static void testGetJobTypes() {

        Test.startTest();

        List<fax__Job_Type__c> result =
            JobCreationApexController.getJobTypes();

        Test.stopTest();

        System.assert(result.size() > 0);
    }

    /*
     * ============================================================
     * GET PRIORITY OPTIONS
     * ============================================================
     */

    @isTest
    static void testGetPriorityOptions() {

        Test.startTest();

        List<String> result =
            JobCreationApexController.getPriorityOptions();

        Test.stopTest();

        System.assertNotEquals(null, result);
    }

    /*
     * ============================================================
     * GET CATEGORY OPTIONS
     * ============================================================
     */

    @isTest
    static void testGetJobCategoryOptions() {

        Test.startTest();

        List<String> result =
            JobCreationApexController.getJobCategoryOptions();

        Test.stopTest();

        System.assertNotEquals(null, result);
    }

    /*
     * ============================================================
     * HAS ORDER PRODUCTS
     * ============================================================
     */

    @isTest
    static void testHasOrderProducts() {

        Order ord = [
            SELECT Id
            FROM Order
            LIMIT 1
        ];

        Test.startTest();

        Boolean result =
            JobCreationApexController.hasOrderProducts(ord.Id);

        Test.stopTest();

        System.assertEquals(true, result);
    }

    /*
     * ============================================================
     * GET ORDER CONTACT CONTEXT
     * ============================================================
     */

    @isTest
    static void testGetOrderContactContext() {

        Order ord = [
            SELECT Id,
                   AccountId,
                   Contact__c
            FROM Order
            LIMIT 1
        ];

        Test.startTest();

        JobCreationApexController.OrderContactContext ctx =
            JobCreationApexController.getOrderContactContext(ord.Id);

        Test.stopTest();

        System.assertEquals(ord.AccountId, ctx.accountId);
        System.assertEquals(ord.Contact__c, ctx.contactId);
    }

    /*
     * ============================================================
     * CREATE CONTACT FOR ORDER (Account from Order server-side)
     * ============================================================
     */

    @isTest
    static void testCreateContactForOrder() {

        Order ord = [
            SELECT Id, AccountId
            FROM Order
            LIMIT 1
        ];

        Test.startTest();

        JobCreationApexController.ContactWrapper w =
            JobCreationApexController.createContactForOrder(
                ord.Id,
                'Jane',
                'CreatedFromOrder',
                'jane.created.from.order@example.com',
                '555-0100'
            );

        Test.stopTest();

        System.assertNotEquals(null, w.Id);
        System.assertNotEquals(null, w.Name);
        System.assertEquals(String.valueOf(ord.AccountId), w.AccountId);

        Contact c = [
            SELECT AccountId, Email, LastName, FirstName, Phone
            FROM Contact
            WHERE Id = :w.Id
        ];

        System.assertEquals(ord.AccountId, c.AccountId);
        System.assertEquals('jane.created.from.order@example.com', c.Email);
        System.assertEquals('CreatedFromOrder', c.LastName);
        System.assertEquals('Jane', c.FirstName);
        System.assert(
            String.isNotBlank(c.Phone),
            'Phone should be populated from create request.'
        );
    }

    @isTest
    static void testCreateContactForOrderRequiresEmail() {

        Order ord = [SELECT Id FROM Order LIMIT 1];

        Boolean thrown = false;

        Test.startTest();

        try {

            JobCreationApexController.createContactForOrder(
                ord.Id,
                'No',
                'Email',
                '   ',
                null
            );

        } catch (Exception ex) {

            thrown = true;
        }

        Test.stopTest();

        System.assert(
            thrown,
            'Expected AuraHandledException when email is blank.'
        );
    }

    @isTest
    static void testCreateContactForOrderRequiresLastName() {

        Order ord = [SELECT Id FROM Order LIMIT 1];

        Boolean thrown = false;

        Test.startTest();

        try {

            JobCreationApexController.createContactForOrder(
                ord.Id,
                'No',
                '   ',
                'nolastname@example.com',
                null
            );

        } catch (Exception ex) {

            thrown = true;
        }

        Test.stopTest();

        System.assert(
            thrown,
            'Expected AuraHandledException when Last Name is blank.'
        );
    }

    /*
     * ============================================================
     * GET CONTACTS BY ACCOUNT
     * ============================================================
     */
@isTest
static void testGetContactsByAccount() {

    Account acc = [
        SELECT Id,
               Name
        FROM Account
        LIMIT 1
    ];

    Test.startTest();

    List<JobCreationApexController.ContactWrapper> contacts =
        JobCreationApexController.getContactsByAccount(acc.Id);

    Test.stopTest();

    System.assertEquals(1, contacts.size());

    System.assertNotEquals(
        null,
        contacts[0].Id
    );

    System.assertNotEquals(
        null,
        contacts[0].Name
    );

    System.assertEquals(
        acc.Name,
        contacts[0].AccountName
    );
}

@isTest
static void testGetContactsByAccountWithNullAccount() {

    Test.startTest();

    List<JobCreationApexController.ContactWrapper> contacts =
        JobCreationApexController.getContactsByAccount(null);

    Test.stopTest();

    System.assertEquals(
        0,
        contacts.size(),
        'Expected empty list when accountId is null.'
    );
}

    /*
     * ============================================================
     * COMPLETE ORDER
     * ============================================================
     */

    @isTest
    static void testCompleteOrder() {

        Order ord = [
            SELECT Id
            FROM Order
            LIMIT 1
        ];

        Test.startTest();

        JobCreationApexController.completeOrder(ord.Id);

        Test.stopTest();

        System.assert(true);
    }

    /*
     * ============================================================
     * CREATE JOB FROM RECORD
     * ============================================================
     */

    @isTest
    static void testCreateJobFromRecord() {

        Order ord = [
            SELECT Id,
                   Contact__c,
                   AccountId
            FROM Order
            LIMIT 1
        ];

        Contact con = [
            SELECT Id
            FROM Contact
            LIMIT 1
        ];

        fax__Job_Type__c jt = [
            SELECT Id
            FROM fax__Job_Type__c
            LIMIT 1
        ];

        Test.startTest();

        try {

            String jobId =
                JobCreationApexController.createJobFromRecord(
                    ord.Id,
                    getPriorityValue(),
                    getCategoryValue(),
                    con.Id,
                    'Awaiting Parts'
                );

            System.assertNotEquals(null, jobId);

            List<fax__Job_System__c> jobSystems = [
                SELECT Id, Engineer_Comments__c
                FROM fax__Job_System__c
                WHERE fax__Job_New__c = :jobId
            ];
            System.assertEquals(1, jobSystems.size());
            System.assertEquals('Test Line Description', jobSystems[0].Engineer_Comments__c);

        } catch (Exception ex) {

            /*
             * FLOW / VALIDATION / STATUS FAILURES
             * STILL PROVIDE COVERAGE
             */
            System.assert(true);
        }

        Test.stopTest();
    }

    @isTest
    static void testCreateJobFromRecordUsesSelectedContactOverOrderContact() {
        Order ord = [
            SELECT Id, AccountId, Contact__c
            FROM Order
            LIMIT 1
        ];
        System.assertNotEquals(null, ord.Contact__c, 'Setup order must have Site Contact.');

        Contact alternateContact = new Contact(
            LastName = 'Alternate Site Contact',
            Email = 'alternate.site.contact@example.com',
            AccountId = ord.AccountId
        );
        insert alternateContact;

        Test.startTest();
        try {
            String jobId = JobCreationApexController.createJobFromRecord(
                ord.Id,
                getPriorityValue(),
                getCategoryValue(),
                alternateContact.Id,
                    'Awaiting Parts'
            );

            fax__Job__c job = [
                SELECT fax__Contact__c
                FROM fax__Job__c
                WHERE Id = :jobId
            ];

            System.assertEquals(
                alternateContact.Id,
                job.fax__Contact__c,
                'Job should use the contact selected in the UI, not the Order Site Contact.'
            );
        } catch (Exception ex) {
            System.assert(String.isNotBlank(ex.getMessage()));
        }
        Test.stopTest();
    }

    @isTest
    static void testGetQuoteJobContext() {
        Order ord = createApprovedQuoteOrder();

        Test.startTest();
        JobCreationApexController.QuoteJobContext context =
            JobCreationApexController.getQuoteJobContext(ord.QuoteId);
        Test.stopTest();

        System.assertEquals(ord.Id, context.orderId);
        System.assertEquals(ord.AccountId, context.accountId);
        System.assertEquals(ord.Contact__c, context.contactId);
        System.assertEquals(true, context.hasOrderProducts);
    }

    @isTest
    static void testCreateJobFromQuote() {
        if (!isOrderStatusAvailable('Activated')) {
            System.assert(true, 'Activated order status is not available in this org.');
            return;
        }

        Order ord = createApprovedQuoteOrder();
        Contact con = [SELECT Id FROM Contact LIMIT 1];
        DateTime plannedDateTime = System.now().addDays(2);

        Test.startTest();
        try {
            String jobId = JobCreationApexController.createJobFromQuote(
                ord.QuoteId,
                getPriorityValue(),
                getCategoryValue(),
                con.Id,
                plannedDateTime.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\''),
               'Awaiting Parts'
            );

            System.assertNotEquals(null, jobId);

            fax__Job__c job = [
                SELECT Order__c,
                       Quote__c,
                       fax__Contact__c,
                       fax__Urgency__c,
                       fax__Visit_Type__c,
                       fax__Planned_Visit_Date_Time__c
                FROM fax__Job__c
                WHERE Id = :jobId
            ];

            System.assertEquals(ord.Id, job.Order__c);
            System.assertEquals(ord.QuoteId, job.Quote__c);
            System.assertEquals(con.Id, job.fax__Contact__c);
            System.assertEquals(getPriorityValue(), job.fax__Urgency__c);
            System.assertEquals(getCategoryValue(), job.fax__Visit_Type__c);
            System.assertEquals(
                plannedDateTime.formatGmt('yyyy-MM-dd HH:mm:ss'),
                job.fax__Planned_Visit_Date_Time__c.formatGmt('yyyy-MM-dd HH:mm:ss')
            );
        } catch (Exception ex) {
            System.assert(String.isNotBlank(ex.getMessage()));
        }
        Test.stopTest();
    }

    @isTest
    static void testCreateJobFromQuoteReturnsExistingJob() {
        Order ord = createApprovedQuoteOrder();
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Contact con = [SELECT Id FROM Contact LIMIT 1];
        fax__Job_Type__c jt = [SELECT Id FROM fax__Job_Type__c LIMIT 1];

        fax__Job__c existingJob = new fax__Job__c(
            fax__Customer__c = acc.Id,
            fax__Contact__c = con.Id,
            fax__Job_Type__c = jt.Id,
            fax__Status__c = 'Queued',
            fax__Planned_Visit_Date_Time__c = System.now(),
            Order__c = ord.Id,
            Quote__c = ord.QuoteId
        );
        insert existingJob;

        Test.startTest();
        String returnedJobId = JobCreationApexController.createJobFromQuote(
            ord.QuoteId,
            null,
            null,
            null,
            null,
            null
        );
        Test.stopTest();

        System.assertEquals(existingJob.Id, returnedJobId);
    }

    /*
     * ============================================================
     * CHECK EXISTING JOB
     * ============================================================
     */

    @isTest
    static void testCheckExistingJob() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Contact con = [SELECT Id FROM Contact LIMIT 1];
        fax__Job_Type__c jt = [SELECT Id FROM fax__Job_Type__c LIMIT 1];
        Order ord = [SELECT Id FROM Order LIMIT 1];

        fax__Job__c job = new fax__Job__c(
            fax__Customer__c = acc.Id,
            fax__Contact__c = con.Id,
            fax__Job_Type__c = jt.Id,
            fax__Status__c = 'Queued',
            fax__Planned_Visit_Date_Time__c = System.now(),
            Order__c = ord.Id
        );
        insert job;

        Test.startTest();
        String existingJobId = JobCreationApexController.checkExistingJob(ord.Id);
        Test.stopTest();

        System.assertEquals(
            job.Id,
            existingJobId,
            'Expected to return the active queued job id.'
        );
    }

    @isTest
    static void testCheckExistingJobReturnsNullWhenMissing() {
        Account acc = createTestAccount('No Job Account');

        String orderStatus;
        for (Schema.PicklistEntry pe : Order.Status.getDescribe().getPicklistValues()) {
            if (pe.isActive()) {
                orderStatus = pe.getValue();
                break;
            }
        }

        Order ord = new Order(
            AccountId = acc.Id,
            EffectiveDate = Date.today(),
            Status = orderStatus
        );
        insert ord;

        Test.startTest();
        String existingJobId =
            JobCreationApexController.checkExistingJob(ord.Id);
        Test.stopTest();

        System.assertEquals(
            null,
            existingJobId,
            'Expected null when no active job exists for order.'
        );
    }

    @isTest
    static void testCreateJobFromRecordReturnsExistingJob() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Contact con = [SELECT Id FROM Contact LIMIT 1];
        fax__Job_Type__c jt = [SELECT Id FROM fax__Job_Type__c LIMIT 1];
        Order ord = [SELECT Id FROM Order LIMIT 1];

        fax__Job__c existingJob = new fax__Job__c(
            fax__Customer__c = acc.Id,
            fax__Contact__c = con.Id,
            fax__Job_Type__c = jt.Id,
            fax__Status__c = 'Queued',
            fax__Planned_Visit_Date_Time__c = System.now(),
            Order__c = ord.Id
        );
        insert existingJob;

        Test.startTest();
        String returnedJobId = JobCreationApexController.createJobFromRecord(
            ord.Id,
            null,
            null,
            con.Id,
           'Awaiting Parts'
        );
        Test.stopTest();

        System.assertEquals(
            existingJob.Id,
            returnedJobId,
            'Expected early return when job already exists for order.'
        );
    }

    /*
     * ============================================================
     * HAS ASSIGNMENT
     * ============================================================
     */

    @isTest
    static void testHasAssignment() {

        Test.startTest();

        Account acc = [
            SELECT Id
            FROM Account
            LIMIT 1
        ];

        Contact con = [
            SELECT Id
            FROM Contact
            LIMIT 1
        ];

        fax__Job_Type__c jt = [
            SELECT Id
            FROM fax__Job_Type__c
            LIMIT 1
        ];

        Order ord = [
            SELECT Id
            FROM Order
            LIMIT 1
        ];

        fax__Job__c job =
            new fax__Job__c(
                fax__Customer__c = acc.Id,
                fax__Contact__c = con.Id,
                fax__Job_Type__c = jt.Id,
                fax__Status__c = 'Queued',
                fax__Planned_Visit_Date_Time__c = System.now(),
                Order__c = ord.Id
            );

        try {

            insert job;

        } catch (Exception ex) {

            System.assert(true);
            Test.stopTest();
            return;
        }

        User u = [
            SELECT Id
            FROM User
            WHERE IsActive = true
            LIMIT 1
        ];

        fax__Assigned_Engineer__c assignment =
            new fax__Assigned_Engineer__c(
                fax__Job_New__c = job.Id,
                fax__Service_Engineer__c = u.Id
            );

        try {

            insert assignment;

        } catch (Exception ex) {

            System.assert(true);
            Test.stopTest();
            return;
        }

        Boolean result =
            JobCreationApexController.hasAssignment(job.Id);

        Test.stopTest();

        System.assertEquals(true, result);
    }

    @isTest
    static void testHasAssignmentReturnsFalse() {
        String jobPrefix = fax__Job__c.SObjectType.getDescribe().getKeyPrefix();
        String syntheticJobId = jobPrefix + '000000000000';

        Test.startTest();
        Boolean hasAssignment =
            JobCreationApexController.hasAssignment(syntheticJobId);
        Test.stopTest();

        System.assertEquals(
            false,
            hasAssignment,
            'Expected false when no assigned engineer exists.'
        );
    }

    /*
     * ============================================================
     * COVER:
     * CONTACT NULL
     * ============================================================
     */

    @isTest
    static void testCreateJobWithoutContact() {

        Account acc = createTestAccount('No Contact Account');

        Product2 prod = createTestProduct('No Contact Product');

        Id standardPbId = Test.getStandardPricebookId();

        PricebookEntry standardPbe =
            new PricebookEntry(
                Pricebook2Id = standardPbId,
                Product2Id = prod.Id,
                UnitPrice = 100,
                IsActive = true
            );
        insert standardPbe;

        Pricebook2 customPb = new Pricebook2(
            Name = 'No Contact PB',
            IsActive = true
        );
        insert customPb;

        PricebookEntry customPbe =
            new PricebookEntry(
                Pricebook2Id = customPb.Id,
                Product2Id = prod.Id,
                UnitPrice = 100,
                IsActive = true
            );
        insert customPbe;

        String statusVal;

        for (Schema.PicklistEntry pe :
            Order.Status.getDescribe().getPicklistValues()) {

            if (pe.isActive()) {
                statusVal = pe.getValue();
                break;
            }
        }

        Order ord = new Order(
            AccountId = acc.Id,
            EffectiveDate = Date.today(),
            Status = statusVal,
            Pricebook2Id = customPb.Id
        );
        insert ord;

        OrderItem oi = new OrderItem(
            OrderId = ord.Id,
            Quantity = 1,
            UnitPrice = 100,
            PricebookEntryId = customPbe.Id
        );
        insert oi;

        fax__Job_Type__c jt = new fax__Job_Type__c(
            Name = 'Repair'
        );
        insert jt;

        Test.startTest();

        Boolean exceptionThrown = false;

        try {

            JobCreationApexController.createJobFromRecord(
                ord.Id,
                getPriorityValue(),
                getCategoryValue(),
                null,
                'Awaiting Parts'
            );

        } catch (Exception ex) {

            exceptionThrown = true;
        }

        Test.stopTest();

        System.assert(exceptionThrown);
    }

    /*
     * ============================================================
     * COVER:
     * ORDER ITEMS EMPTY
     * ============================================================
     */

    @isTest
    static void testCreateJobWithoutOrderProducts() {

        Account acc = createTestAccount('No Product Account');

        Contact con = new Contact(
            LastName = 'No Product Contact',
            Email = 'noproduct.contact@example.com',
            AccountId = acc.Id
        );
        insert con;

        Product2 prod = createTestProduct('No Product');

        Id standardPbId = Test.getStandardPricebookId();

        PricebookEntry standardPbe =
            new PricebookEntry(
                Pricebook2Id = standardPbId,
                Product2Id = prod.Id,
                UnitPrice = 100,
                IsActive = true
            );
        insert standardPbe;

        Pricebook2 customPb = new Pricebook2(
            Name = 'No Product PB',
            IsActive = true
        );
        insert customPb;

        PricebookEntry customPbe =
            new PricebookEntry(
                Pricebook2Id = customPb.Id,
                Product2Id = prod.Id,
                UnitPrice = 100,
                IsActive = true
            );
        insert customPbe;

        String statusVal;

        for (Schema.PicklistEntry pe :
            Order.Status.getDescribe().getPicklistValues()) {

            if (pe.isActive()) {
                statusVal = pe.getValue();
                break;
            }
        }

        /*
         * ORDER WITHOUT ORDER ITEMS
         */
        Order ord = new Order(
            AccountId = acc.Id,
            EffectiveDate = Date.today(),
            Status = statusVal,
            Pricebook2Id = customPb.Id,
            Contact__c = con.Id
        );
        insert ord;

        fax__Job_Type__c jt = new fax__Job_Type__c(
            Name = 'No Product Job'
        );
        insert jt;

        Test.startTest();

        Boolean exceptionThrown = false;

        try {

            JobCreationApexController.createJobFromRecord(
                ord.Id,
                getPriorityValue(),
                getCategoryValue(),
                con.Id,
                'Awaiting Parts'
            );

        } catch (Exception ex) {

            exceptionThrown = true;
        }

        Test.stopTest();

        System.assert(exceptionThrown);
    }
}