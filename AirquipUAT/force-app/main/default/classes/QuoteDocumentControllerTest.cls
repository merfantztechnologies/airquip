@isTest
private class QuoteDocumentControllerTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(
            Name = 'Test Account',
            BillingStreet = '123 Test Street',
            BillingCity = 'Test City',
            BillingState = 'California',
            BillingPostalCode = '12345',
            BillingCountry = 'United States',
            ShippingStreet = '123 Test Street',
            ShippingCity = 'Test City',
            ShippingState = 'California',
            ShippingPostalCode = '12345',
            ShippingCountry = 'United States'
        );
        insert acc;

        Contact con = new Contact(
            FirstName = 'Jane',
            LastName = 'Doe',
            Email = 'jane.doe@example.com',
            AccountId = acc.Id
        );
        insert con;
        
        Opportunity opp = new Opportunity(
            Name = 'Test Opp',
            AccountId = acc.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            Contact__c = con.Id
        );
        insert opp;

        insert new Quote(
            Name = 'Test Quote',
            QuoteAccountId = acc.Id,
            OpportunityId = opp.Id,
            Status = 'Draft'
        );
    }

    static Id getQuoteId() {
        return [SELECT Id FROM Quote LIMIT 1].Id;
    }

    @isTest
    static void testGenerateQuoteDocument_Success() {
        Id quoteId = getQuoteId();

        Test.startTest();
        Id docId = QuoteDocumentController.generateQuoteDocument(quoteId, 'QuotePreview');
        Test.stopTest();

        System.assertNotEquals(null, docId);
        QuoteDocument qd = [SELECT Id, QuoteId FROM QuoteDocument WHERE Id = :docId LIMIT 1];
        System.assertEquals(quoteId, qd.QuoteId);
    }

    @isTest
    static void testGenerateQuoteDocument_SummaryFormatSuccess() {
        Id quoteId = getQuoteId();

        Test.startTest();
        Id docId = QuoteDocumentController.generateQuoteDocument(quoteId, 'QuoteSummaryFormatPreview');
        Test.stopTest();

        System.assertNotEquals(null, docId);
        QuoteDocument qd = [SELECT Id, QuoteId FROM QuoteDocument WHERE Id = :docId LIMIT 1];
        System.assertEquals(quoteId, qd.QuoteId);
    }

    @isTest
    static void testGenerateQuoteDocument_InvalidFormatDefaults() {
        Id quoteId = getQuoteId();

        Test.startTest();
        Id docId = QuoteDocumentController.generateQuoteDocument(quoteId, 'NotAllowedPage');
        Test.stopTest();

        System.assertNotEquals(null, docId);
        QuoteDocument qd = [SELECT Id, QuoteId FROM QuoteDocument WHERE Id = :docId LIMIT 1];
        System.assertEquals(quoteId, qd.QuoteId);
    }

    @isTest
    static void testGenerateQuoteDocument_NullId_ThrowsException() {
        Boolean threw = false;
        Test.startTest();
        try {
            QuoteDocumentController.generateQuoteDocument(null, 'QuotePreview');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw);
    }

    @isTest
    static void testGenerateQuoteDocument_InvalidId_CatchBlock() {
        // Pass a valid-format but non-existent Quote Id to trigger the catch block
        Boolean threw = false;
        Test.startTest();
        try {
            QuoteDocumentController.generateQuoteDocument('0Q0000000000000AAA', 'QuotePreview');
        } catch (AuraHandledException e) {
            threw = true;
            System.assert(e.getMessage().contains('Script-thrown exception') || e.getMessage() != null);
        }
        Test.stopTest();
        System.assert(threw);
    }

    @isTest
    static void testGetQuoteDocumentDetails_Success() {
        Id quoteId = getQuoteId();

        Test.startTest();
        Id docId = QuoteDocumentController.generateQuoteDocument(quoteId, null);
        QuoteDocument result = QuoteDocumentController.getQuoteDocumentDetails(docId);
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(docId, result.Id);
    }
}