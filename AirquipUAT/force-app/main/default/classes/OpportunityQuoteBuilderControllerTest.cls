@IsTest
private class OpportunityQuoteBuilderControllerTest {

    @TestSetup
    static void data() {
        Account acc = new Account(
            Name = 'Ctx Account',
            BillingStreet = '100 Main St',
            BillingCity = 'Austin',
            BillingCountryCode = 'US',
            BillingStateCode = 'TX',
            BillingPostalCode = '78701',
            ShippingStreet = '100 Main St',
            ShippingCity = 'Austin',
            ShippingCountryCode = 'US',
            ShippingStateCode = 'TX',
            ShippingPostalCode = '78701'
        );
        insert acc;

        Contact con = new Contact(FirstName = 'A', LastName = 'B', AccountId = acc.Id);
        insert con;

        Case cse = new Case(Subject = 'T', AccountId = acc.Id, ContactId = con.Id);
        insert cse;

        Id stdPb = Test.getStandardPricebookId();
        try {
            update new Pricebook2(Id = stdPb, IsActive = true);
        } catch (Exception e) {
            // ignore standard pricebook lock contention in parallel tests
        }

        Product2 prod = new Product2(
            Name = 'Line Prod',
            IsActive = true,
            Family = 'Hardware'
        );
        insert prod;

        insert new PricebookEntry(
            Pricebook2Id = stdPb,
            Product2Id = prod.Id,
            UnitPrice = 50,
            IsActive = true
        );

        Opportunity opp = new Opportunity(
            Name = 'Existing Opp',
            AccountId = acc.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(10),
            Pricebook2Id = stdPb
        );
        insert opp;

        insert new Quote(
            Name = 'Seed Quote',
            QuoteAccountId = acc.Id,
            OpportunityId = opp.Id,
            Pricebook2Id = stdPb,
            ContactId = con.Id,
            Status = 'Draft'
        );
    }

    @IsTest
    static void testCreate_fromCase() {
        Case cse = [SELECT Id FROM Case LIMIT 1];
        OpportunityQuoteBuilderController.LineInput li = new OpportunityQuoteBuilderController.LineInput();
        li.pricebookEntryId = [SELECT Id FROM PricebookEntry LIMIT 1].Id;
        li.quantity = 2;
        li.unitPrice = 40;

        Test.startTest();
        OpportunityQuoteBuilderController.CreateResult res = OpportunityQuoteBuilderController.createOpportunityQuoteAndLines(
            cse.Id,
            null,
            null,
            null,
            'Opp From Case',
            'Quote From Case',
            Date.today().addDays(14),
            'Customer needs replacement parts.',
            new List<OpportunityQuoteBuilderController.LineInput>{ li }
        );
        Test.stopTest();

        System.assertNotEquals(null, res.opportunityId);
        System.assertNotEquals(null, res.quoteId);
        System.assertEquals(
            1,
            [SELECT COUNT() FROM QuoteLineItem WHERE QuoteId = :res.quoteId]
        );
        System.assertEquals(
            1,
            [SELECT COUNT() FROM OpportunityLineItem WHERE OpportunityId = :res.opportunityId]
        );
        Opportunity createdOpp = [SELECT StageName, Description FROM Opportunity WHERE Id = :res.opportunityId];
        System.assertEquals('Solution Proposed / Quote Sent', createdOpp.StageName);
        System.assertEquals('Customer needs replacement parts.', createdOpp.Description);
        Quote createdQuote = [SELECT Status, Description FROM Quote WHERE Id = :res.quoteId];
        System.assertEquals('Draft', createdQuote.Status);
        System.assertEquals('Customer needs replacement parts.', createdQuote.Description);
    }

    @IsTest
    static void testCreate_fromOpportunity_reusesOpp() {
        Opportunity opp = [SELECT Id, AccountId FROM Opportunity WHERE Name = 'Existing Opp' LIMIT 1];
        OpportunityQuoteBuilderController.LineInput li = new OpportunityQuoteBuilderController.LineInput();
        li.pricebookEntryId = [SELECT Id FROM PricebookEntry LIMIT 1].Id;
        li.quantity = 1;
        li.unitPrice = 50;

        Test.startTest();
        OpportunityQuoteBuilderController.CreateResult res = OpportunityQuoteBuilderController.createOpportunityQuoteAndLines(
            opp.Id,
            opp.AccountId,
            null,
            opp.Id,
            'ignored name for existing',
            'Child Quote',
            null,
            'Reuse existing opportunity.',
            new List<OpportunityQuoteBuilderController.LineInput>{ li }
        );
        Test.stopTest();

        System.assertEquals(opp.Id, res.opportunityId);
        Quote q = [SELECT Id, OpportunityId FROM Quote WHERE Id = :res.quoteId];
        System.assertEquals(opp.Id, q.OpportunityId);
    }

    @IsTest
    static void testGetStandardActivePricebookId() {
        System.assertEquals(
            Test.getStandardPricebookId(),
            OpportunityQuoteBuilderController.getStandardActivePricebookId()
        );
    }

    @IsTest
    static void testContext_fromQuote_usesQuoteAccountAndStandardPb() {
        Quote q = [SELECT Id, QuoteAccountId FROM Quote WHERE Name = 'Seed Quote' LIMIT 1];
        OpportunityQuoteBuilderController.SourceContext ctx = OpportunityQuoteBuilderController.getSourceContext(q.Id);
        System.assertEquals(q.QuoteAccountId, ctx.accountId);
        System.assertEquals(Test.getStandardPricebookId(), ctx.pricebookId);
    }

    @IsTest
    static void testContextAndSearch() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        OpportunityQuoteBuilderController.SourceContext ctx = OpportunityQuoteBuilderController.getSourceContext(acc.Id);
        System.assertEquals(acc.Id, ctx.accountId);

        List<OpportunityQuoteBuilderController.PbeOption> rows = OpportunityQuoteBuilderController.searchPricebookEntries(
            ctx.pricebookId,
            'Line'
        );
        System.assert(!rows.isEmpty());
    }

    @IsTest
    static void testLookupHelpers() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        List<OpportunityQuoteBuilderController.AccountOption> accounts =
            OpportunityQuoteBuilderController.searchAccounts('Ctx');
        List<OpportunityQuoteBuilderController.ContactOption> contacts =
            OpportunityQuoteBuilderController.getContacts(acc.Id);
        List<OpportunityQuoteBuilderController.OpportunityOption> opportunities =
            OpportunityQuoteBuilderController.getOpportunities(acc.Id);
        Test.stopTest();

        System.assert(!accounts.isEmpty());
        System.assert(!contacts.isEmpty());
        System.assert(!opportunities.isEmpty());
    }

    @IsTest
    static void testCreateContactHelper() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        OpportunityQuoteBuilderController.ContactOption created =
            OpportunityQuoteBuilderController.createContact(
                acc.Id,
                'New Quote Contact',
                'quote.contact@example.com',
                '555-1212'
            );
        Test.stopTest();

        System.assertNotEquals(null, created.contactId);
        System.assertEquals('New Quote Contact - quote.contact@example.com', created.label);
        Contact con = [SELECT AccountId, FirstName, LastName, Email, Phone FROM Contact WHERE Id = :created.contactId];
        System.assertEquals(acc.Id, con.AccountId);
        System.assertEquals('New Quote', con.FirstName);
        System.assertEquals('Contact', con.LastName);
        System.assertEquals('quote.contact@example.com', con.Email);
        System.assertEquals('555-1212', con.Phone);
    }

    @IsTest
    static void testCreate_fromList_noSource_withAccount() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Contact con = [SELECT Id FROM Contact WHERE AccountId = :acc.Id LIMIT 1];
        OpportunityQuoteBuilderController.LineInput li = new OpportunityQuoteBuilderController.LineInput();
        li.pricebookEntryId = [SELECT Id FROM PricebookEntry LIMIT 1].Id;
        li.quantity = 3;
        li.unitPrice = 45;
        li.description = 'List-view line description';
        li.includeInQuote = true;

        Test.startTest();
        OpportunityQuoteBuilderController.CreateResult res = OpportunityQuoteBuilderController.createOpportunityQuoteAndLines(
            null,
            acc.Id,
            con.Id,
            null,
            'List View Opp',
            'List View Quote',
            Date.today().addDays(30),
            'Standalone quote description',
            new List<OpportunityQuoteBuilderController.LineInput>{ li }
        );
        Test.stopTest();

        Opportunity opp = [SELECT AccountId, StageName FROM Opportunity WHERE Id = :res.opportunityId];
        System.assertEquals(acc.Id, opp.AccountId);
        System.assertEquals('Solution Proposed / Quote Sent', opp.StageName);
        Quote q = [SELECT QuoteAccountId, ContactId, Status FROM Quote WHERE Id = :res.quoteId];
        System.assertEquals(acc.Id, q.QuoteAccountId);
        System.assertEquals(con.Id, q.ContactId);
        System.assertEquals('Draft', q.Status);
        Id quoteId = res.quoteId;
        Map<String, Schema.SObjectField> qliFields = QuoteLineItem.SObjectType.getDescribe().fields.getMap();
        if (qliFields.containsKey('line_item_description__c')) {
            QuoteLineItem qli = [
                SELECT Description, Include_In_Quote__c, Line_Item_Description__c
                FROM QuoteLineItem
                WHERE QuoteId = :quoteId
                LIMIT 1
            ];
            System.assertEquals('List-view line description', qli.Description);
            System.assertEquals(true, qli.Include_In_Quote__c);
            System.assertEquals('List-view line description', qli.Line_Item_Description__c);
        } else {
            QuoteLineItem qli = [
                SELECT Description, Include_In_Quote__c
                FROM QuoteLineItem
                WHERE QuoteId = :quoteId
                LIMIT 1
            ];
            System.assertEquals('List-view line description', qli.Description);
            System.assertEquals(true, qli.Include_In_Quote__c);
        }
    }

    @IsTest
    static void testCreate_fromList_attachesToExistingOpportunity() {
        Opportunity opp = [SELECT Id, AccountId FROM Opportunity WHERE Name = 'Existing Opp' LIMIT 1];
        OpportunityQuoteBuilderController.LineInput li = new OpportunityQuoteBuilderController.LineInput();
        li.pricebookEntryId = [SELECT Id FROM PricebookEntry LIMIT 1].Id;
        li.quantity = 1;
        li.unitPrice = 50;

        Test.startTest();
        OpportunityQuoteBuilderController.CreateResult res = OpportunityQuoteBuilderController.createOpportunityQuoteAndLines(
            null,
            opp.AccountId,
            null,
            opp.Id,
            '',
            'Existing Opportunity Quote',
            null,
            null,
            new List<OpportunityQuoteBuilderController.LineInput>{ li }
        );
        Test.stopTest();

        System.assertEquals(opp.Id, res.opportunityId);
        Quote q = [SELECT OpportunityId, Status FROM Quote WHERE Id = :res.quoteId];
        System.assertEquals(opp.Id, q.OpportunityId);
        System.assertEquals('Draft', q.Status);
    }
}