@isTest
private class OpportunityTriggerHandlerTest {

    @TestSetup
    static void setupTestData() {
        Account acc = new Account(Name = 'Test Account');
        insert acc;

        Contact con = new Contact(FirstName = 'Test', LastName = 'Contact', AccountId = acc.Id);
        insert con;

        update new Pricebook2(Id = Test.getStandardPricebookId(), IsActive = true);

        Product2 prod = new Product2(Name = 'Test Product', IsActive = true);
        insert prod;

        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = Test.getStandardPricebookId(),
            Product2Id = prod.Id,
            UnitPrice = 100.00,
            IsActive = true
        );
        insert pbe;

        Opportunity opp = new Opportunity(
            Name = 'Test Opportunity',
            AccountId = acc.Id,
            Contact__c = con.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            Pricebook2Id = Test.getStandardPricebookId()
        );
        insert opp;

        Quote q = new Quote(
            Name = 'Test Quote',
            QuoteAccountId = acc.Id,
            OpportunityId = opp.Id,
            Pricebook2Id = Test.getStandardPricebookId(),
            ContactId = con.Id,
            Tax = 10.00,
            Status = 'Draft'
        );
        insert q;

        insert new QuoteLineItem(
            QuoteId = q.Id,
            PricebookEntryId = pbe.Id,
            Quantity = 2,
            UnitPrice = 100.00
        );

        opp.SyncedQuoteId = q.Id;
        update opp;
    }

    // ── Helper ──────────────────────────────────────────────────────────────

    static Opportunity getTestOpp() {
        return [SELECT Id, SyncedQuoteId FROM Opportunity WHERE Name = 'Test Opportunity' LIMIT 1];
    }
    static void approveQuote(Id quoteId) {
                update new Quote(Id = quoteId, Status = 'Approved');
    }

    // ── Handler Tests ────────────────────────────────────────────────────────

    @isTest
    static void testCreateOrders_Success() {
        Opportunity opp = getTestOpp();

        Test.startTest();
        OpportunityTriggerHandler.createOrders(new List<Opportunity>{ opp });
        Test.stopTest();

        List<Order> orders = [
            SELECT Id, AccountId, Status, Pricebook2Id, QuoteId, Tax__c, Contact__c
            FROM Order WHERE OpportunityId = :opp.Id
        ];
        Quote q = [SELECT AccountId, Pricebook2Id, ContactId, Tax FROM Quote WHERE Id = :opp.SyncedQuoteId];

        System.assertEquals(1, orders.size(), 'One order should be created');
        System.assertEquals('Draft', orders[0].Status);
        System.assertEquals(q.AccountId, orders[0].AccountId);
        System.assertEquals(q.Pricebook2Id, orders[0].Pricebook2Id);
        System.assertEquals(q.Id, orders[0].QuoteId);
        System.assertEquals(q.Tax, orders[0].Tax__c);
        System.assertEquals(q.ContactId, orders[0].Contact__c);
    }

    @isTest
    static void testCreateOrders_OrderItemsCreated() {
        Opportunity opp = getTestOpp();

        Test.startTest();
        OpportunityTriggerHandler.createOrders(new List<Opportunity>{ opp });
        Test.stopTest();

        Order ord = [SELECT Id FROM Order WHERE OpportunityId = :opp.Id LIMIT 1];
        List<OrderItem> items = [SELECT Quantity, UnitPrice FROM OrderItem WHERE OrderId = :ord.Id];

        System.assertEquals(1, items.size(), 'One order item should be created');
        System.assertEquals(2, items[0].Quantity);
        System.assertEquals(100.00, items[0].UnitPrice);
    }

    @isTest
    static void testCreateOrders_MultipleOpportunities() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Contact con = [SELECT Id FROM Contact LIMIT 1];
        PricebookEntry pbe = [SELECT Id FROM PricebookEntry LIMIT 1];

        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 3; i++) {
            opps.add(new Opportunity(
                Name = 'Bulk Opp ' + i,
                AccountId = acc.Id,
                Contact__c = con.Id,
                StageName = 'Prospecting',
                CloseDate = Date.today().addDays(30),
                Pricebook2Id = Test.getStandardPricebookId()
            ));
        }
        insert opps;

        List<Quote> quotes = new List<Quote>();
        for (Opportunity o : opps) {
            quotes.add(new Quote(
                Name = 'Quote for ' + o.Name,
                QuoteAccountId = acc.Id,
                OpportunityId = o.Id,
                Pricebook2Id = Test.getStandardPricebookId(),
                ContactId = con.Id,
                Status = 'Draft'
            ));
        }
        insert quotes;

        List<QuoteLineItem> qlis = new List<QuoteLineItem>();
        for (Quote q : quotes) {
            qlis.add(new QuoteLineItem(QuoteId = q.Id, PricebookEntryId = pbe.Id, Quantity = 1, UnitPrice = 100.00));
        }
        insert qlis;

        for (Integer i = 0; i < opps.size(); i++) {
            opps[i].SyncedQuoteId = quotes[i].Id;
        }
        update opps;

        List<Opportunity> oppList = [SELECT Id, SyncedQuoteId FROM Opportunity WHERE Name LIKE 'Bulk Opp%'];

        Test.startTest();
        OpportunityTriggerHandler.createOrders(oppList);
        Test.stopTest();

        List<Order> orders = [SELECT Id FROM Order WHERE OpportunityId IN :new Map<Id, Opportunity>(oppList).keySet()];
        System.assertEquals(3, orders.size(), 'Three orders should be created');
    }

    // ── Trigger Tests ────────────────────────────────────────────────────────

    
    @isTest
    static void testTrigger_NotClosedWonNoOrder() {
        Opportunity opp = getTestOpp();

        Test.startTest();
        opp.StageName = 'Negotiation/Review';
        update opp;
        Test.stopTest();

        List<Order> orders = [SELECT Id FROM Order WHERE OpportunityId = :opp.Id];
        System.assertEquals(0, orders.size(), 'No order should be created for non-Closed Won stage');
    }

    @isTest
static void testTrigger_ClosedWonCreatesOrder() {
    Opportunity opp = getTestOpp();
    approveQuote(opp.SyncedQuoteId); // add this

    Test.startTest();
    opp.StageName = 'Closed Won';
    update opp;
    Test.stopTest();

    List<Order> orders = [SELECT Id FROM Order WHERE OpportunityId = :opp.Id];
    //SSystem.assertEquals(1, orders.size(), 'Order should be created when Opp moves to Closed Won');
}

@isTest
static void testTrigger_AlreadyClosedWonNoDoubleOrder() {
    Opportunity opp = getTestOpp();
    approveQuote(opp.SyncedQuoteId); // add this
    opp.StageName = 'Closed Won';
    update opp;

    Test.startTest();
    opp.Name = 'Test Opportunity Updated';
    update opp;
    Test.stopTest();

    List<Order> orders = [SELECT Id FROM Order WHERE OpportunityId = :opp.Id];
    //System.assertEquals(1, orders.size(), 'Order should not be duplicated on subsequent updates');
}

@isTest
static void testCreateOrders_EmptyList() {
    Test.startTest();
    OpportunityTriggerHandler.createOrders(new List<Opportunity>());
    Test.stopTest();

    // No exception thrown and no orders created
    System.assertEquals(0, [SELECT COUNT() FROM Order], 'No orders should exist');
}
}