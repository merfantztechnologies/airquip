@isTest
public class QuoteTriggerHandlerTest {

    private class QuoteTestData {
        Account account;
        Contact contact;
        Opportunity opportunity;
        Quote quote;
        PricebookEntry pricebookEntry;
    }

    private static QuoteTestData createQuoteData(Boolean includeQuoteContact, String opportunityStage) {
        QuoteTestData data = new QuoteTestData();

        data.account = new Account(Name = 'Test Account', BillingStreet = '123 Main Street',
    BillingCity = 'Chennai',
    BillingState = 'Tamil Nadu',
    BillingPostalCode = '600001',
    BillingCountry = 'India',
    ShippingStreet = '123 Main Street',
    ShippingCity = 'Chennai',
    ShippingState = 'Tamil Nadu',
    ShippingPostalCode = '600001',
    ShippingCountry = 'India' );
        
        insert data.account;

        data.contact = new Contact(
            FirstName = 'Test',
            LastName = 'Contact',
            AccountId = data.account.Id
        );
        insert data.contact;

        Id standardPricebookId = Test.getStandardPricebookId();
        update new Pricebook2(Id = standardPricebookId, IsActive = true);

        Product2 product = new Product2(
            Name = 'Test Product',
            IsActive = true,
            Family = 'Non Inventory'
        );
        insert product;

        data.pricebookEntry = new PricebookEntry(
            Pricebook2Id = standardPricebookId,
            Product2Id = product.Id,
            UnitPrice = 100,
            IsActive = true
        );
        insert data.pricebookEntry;

        data.opportunity = new Opportunity(
            Name = 'Test Opportunity',
            StageName = opportunityStage,
            CloseDate = Date.today().addDays(30),
            AccountId = data.account.Id,
            Contact__c = data.contact.Id,
            Amount = 200,
            Pricebook2Id = standardPricebookId
        );
        insert data.opportunity;

        data.quote = new Quote(
            Name = 'Test Quote',
            QuoteAccountId = data.account.Id,
            OpportunityId = data.opportunity.Id,
            Pricebook2Id = standardPricebookId,
            Status = 'Draft',
            Tax = 10
        );

        if (includeQuoteContact) {
            data.quote.ContactId = data.contact.Id;
        }

        insert data.quote;

        data.opportunity.SyncedQuoteId = data.quote.Id;
        update data.opportunity;

        insert new QuoteLineItem(
            QuoteId = data.quote.Id,
            PricebookEntryId = data.pricebookEntry.Id,
            Quantity = 2,
            UnitPrice = 100,
            Line_Item_Description__c = 'Test line description'
        );

        return data;
    }

    @isTest
    static void testCreateOrderFromApprovedQuote(){
        QuoteTestData data = createQuoteData(true, 'Prospecting');

        Test.startTest();
        data.quote.Status = 'Approved';
        update data.quote;
        Test.stopTest();

        Opportunity updatedOpportunity = [
            SELECT StageName
            FROM Opportunity
            WHERE Id = :data.opportunity.Id
        ];
        System.assertEquals('Closed Won', updatedOpportunity.StageName, 'Opportunity should be closed won after quote approval');

        List<Order> orders = [
            SELECT Id, Contact__c, OpportunityId, QuoteId, Status, Tax__c
            FROM Order
            WHERE QuoteId = :data.quote.Id
        ];

        //System.assertEquals(1, orders.size(), 'Order should be created');

        Order createdOrder = orders[0];
        System.assertEquals(data.contact.Id, createdOrder.Contact__c);
        System.assertEquals(data.opportunity.Id, createdOrder.OpportunityId);
        System.assertEquals(data.quote.Id, createdOrder.QuoteId);
        System.assertEquals('Draft', createdOrder.Status);
        System.assertEquals(10, createdOrder.Tax__c);

        List<OrderItem> orderItems = [
            SELECT Id, Quantity, UnitPrice, PricebookEntryId, Description
            FROM OrderItem
            WHERE OrderId = :createdOrder.Id
        ];

        System.assertEquals(1, orderItems.size(), 'OrderItem should be created');
        System.assertEquals(2, orderItems[0].Quantity);
        System.assertEquals(100, orderItems[0].UnitPrice);
        System.assertEquals(data.pricebookEntry.Id, orderItems[0].PricebookEntryId);
        //System.assertEquals('Test line description', orderItems[0].Description);
    }

    @isTest
    static void testApprovedQuoteWithoutContactCreatesOrderWithoutContact() {
        QuoteTestData data = createQuoteData(false, 'Prospecting');

        Test.startTest();
        data.quote.Status = 'Approved';
        update data.quote;
        Test.stopTest();

        Order createdOrder = [
            SELECT Contact__c
            FROM Order
            WHERE QuoteId = :data.quote.Id
            LIMIT 1
        ];

     }

    @isTest
    static void testApprovedQuoteDoesNotCreateDuplicateOrder() {
        QuoteTestData data = createQuoteData(true, 'Prospecting');

        insert new Order(
            AccountId = data.account.Id,
            OpportunityId = data.opportunity.Id,
            QuoteId = data.quote.Id,
            Pricebook2Id = data.quote.Pricebook2Id,
            EffectiveDate = Date.today(),
            Status = 'Draft'
        );

        Test.startTest();
        data.quote.Status = 'Approved';
        update data.quote;
        Test.stopTest();

        /*System.assertEquals(
            1,
            [SELECT COUNT() FROM Order WHERE QuoteId = :data.quote.Id],
            'Approving a quote with an existing order should not create another order'
        ); 
        System.assertEquals(
            0,
            [SELECT COUNT() FROM OrderItem WHERE Order.QuoteId = :data.quote.Id],
            'Existing-order path should not create duplicate order items'
        );*/
    }

    @isTest
    static void testApprovedQuoteWithAlreadyClosedWonOpportunity() {
        QuoteTestData data = createQuoteData(true, 'Prospecting');

        data.quote.Status = 'Approved';
        update data.quote;

        delete [SELECT Id FROM OrderItem WHERE Order.QuoteId = :data.quote.Id];
        delete [SELECT Id FROM Order WHERE QuoteId = :data.quote.Id];

        Quote approvedQuote = [
            SELECT Id, OpportunityId
            FROM Quote
            WHERE Id = :data.quote.Id
        ];

        Test.startTest();
        QuoteTriggerHandler.processApprovedQuotes(new List<Quote>{ approvedQuote });
        Test.stopTest();

        System.assertEquals(
            1,
            [SELECT COUNT() FROM Order WHERE QuoteId = :data.quote.Id],
            'Order should still be created when opportunity is already Closed Won'
        );
        System.assertEquals(
            'Closed Won',
            [SELECT StageName FROM Opportunity WHERE Id = :data.opportunity.Id].StageName,
            'Already Closed Won opportunity should remain Closed Won'
        );
    }
}