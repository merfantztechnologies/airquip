@isTest
private class QuotePDFControllerTest {

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
            Email = 'jane@test.com',
            AccountId = acc.Id
        );
        insert con;

        Id stdPbId = Test.getStandardPricebookId();

        Opportunity opp = new Opportunity(
            Name = 'Test Opp',
            AccountId = acc.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            Pricebook2Id = stdPbId,
            Contact__c = con.Id
        );
        insert opp;

        Product2 prod = new Product2(
            Name = 'Test Product',
            ProductCode = 'TP001',
            Family = 'Hardware',
            IsActive = true
        );
        insert prod;

        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = stdPbId,
            Product2Id = prod.Id,
            UnitPrice = 100,
            IsActive = true
        );
        insert pbe;

        Quote q = new Quote(
            Name = 'Test Quote',
            QuoteAccountId = acc.Id,
            OpportunityId = opp.Id,
            Pricebook2Id = stdPbId,
            Status = 'Draft',
            Email = 'test@test.com',
            BillingCity = 'City',
            ShippingCity = 'City'
        );
        insert q;

        insert new QuoteLineItem(
            QuoteId = q.Id,
            PricebookEntryId = pbe.Id,
            Quantity = 2,
            UnitPrice = 100
        );
    }

    static Id getQuoteId() {
        return [SELECT Id FROM Quote LIMIT 1].Id;
    }

    @isTest
    static void testConstructor_WithValidId() {
        Test.setCurrentPage(Page.QuotePreview);
        ApexPages.currentPage().getParameters().put('id', getQuoteId());

        Test.startTest();
        QuotePDFController ctrl = new QuotePDFController();
        Test.stopTest();

        System.assertNotEquals(null, ctrl.q);
        System.assertEquals(1, ctrl.lines.size());
        System.assertEquals(1, ctrl.lineItemWrappers.size());
        System.assertEquals('Test Product', ctrl.lineItemWrappers[0].wrappedProductName);
        System.assertNotEquals(null, ctrl.lineItemWrappers[0].formattedUnitPrice);
    }

    @isTest
    static void testWrappedProductName_EscapesHtmlSpecialCharacters() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test Account' LIMIT 1];
        Contact con = [SELECT Id FROM Contact WHERE AccountId = :acc.Id LIMIT 1];
        Id stdPbId = Test.getStandardPricebookId();

        Opportunity opp = new Opportunity(
            Name = 'Angle Bracket Opp',
            AccountId = acc.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            Pricebook2Id = stdPbId,
            Contact__c = con.Id
        );
        insert opp;

        Product2 prod = new Product2(
            Name = '<00504-054',
            ProductCode = 'ANGLE-001',
            Family = 'Hardware',
            IsActive = true
        );
        insert prod;

        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = stdPbId,
            Product2Id = prod.Id,
            UnitPrice = 56,
            IsActive = true
        );
        insert pbe;

        Quote q = new Quote(
            Name = 'Angle Bracket Quote',
            QuoteAccountId = acc.Id,
            OpportunityId = opp.Id,
            Pricebook2Id = stdPbId,
            Status = 'Draft'
        );
        insert q;

        insert new QuoteLineItem(
            QuoteId = q.Id,
            PricebookEntryId = pbe.Id,
            Quantity = 1,
            UnitPrice = 56,
            Line_Item_Description__c = '<ELB,RUBBER RED',
            Include_In_Quote__c = true
        );

        Test.setCurrentPage(Page.QuotePreview);
        ApexPages.currentPage().getParameters().put('id', q.Id);

        Test.startTest();
        QuotePDFController ctrl = new QuotePDFController();
        Test.stopTest();

        System.assertEquals(1, ctrl.lineItemWrappers.size());
        System.assertEquals('&lt;00504-054', ctrl.lineItemWrappers[0].wrappedProductName);
        System.assertEquals('<ELB,RUBBER RED', ctrl.lineItemWrappers[0].lineItemDescription);
        System.assert(!ctrl.lineItemWrappers[0].wrappedProductName.contains('<00504'));
    }

    @isTest
    static void testFormatCurrencyForPdfWrap_FitsLineWithoutBreak() {
        String result = QuotePDFController.formatCurrencyForPdfWrap(1000000000);

        System.assertEquals('$1,000,000,000.00', result);
        System.assert(!result.contains('<br/>'));
    }

    @isTest
    static void testFormatCurrencyForPdfWrap_WrapsWhenTooLongForLine() {
        String result = QuotePDFController.formatCurrencyForPdfWrap(10000000000.00);

        System.assert(result.contains('<br/>'));
    }

    @isTest
    static void testFormatCurrencyForPdfWrap_LongAmount() {
        String result = QuotePDFController.formatCurrencyForPdfWrap(1234567890123.45);

        System.assert(result.startsWith('$'));
        System.assert(result.contains('<br/>'));
        System.assert(result.endsWith('123.45'));
    }

    @isTest
    static void testConstructor_NoId() {
        Test.setCurrentPage(Page.QuotePreview);

        Test.startTest();
        QuotePDFController ctrl = new QuotePDFController();
        Test.stopTest();

        System.assertEquals(null, ctrl.q);
    }

    @isTest
    static void testConstructor_InvalidId() {
        Test.setCurrentPage(Page.QuotePreview);
        ApexPages.currentPage().getParameters().put('id', '0Q0000000000000AAA');

        Test.startTest();
        QuotePDFController ctrl = new QuotePDFController();
        Test.stopTest();

        System.assertEquals(null, ctrl.q);
        System.assert(ApexPages.hasMessages());
    }

    @isTest
    static void testGetPreviewName_WithQuote() {
        Test.setCurrentPage(Page.QuotePreview);
        ApexPages.currentPage().getParameters().put('id', getQuoteId());

        Test.startTest();
        QuotePDFController ctrl = new QuotePDFController();
        String fileName = ctrl.getPreviewName();
        Test.stopTest();

        System.assert(fileName.startsWith('Airquip_Test_Account_'));
        System.assert(fileName.endsWith('.pdf'));
    }

    @isTest
    static void testGetPreviewName_NoQuote() {
        Test.setCurrentPage(Page.QuotePreview);

        Test.startTest();
        QuotePDFController ctrl = new QuotePDFController();
        Test.stopTest();

        System.assertEquals('Quote.pdf', ctrl.getPreviewName());
    }

    @isTest
    static void testGetPreviewName_SpecialCharacters() {
        Account acc = new Account(
            Name = 'Test@Account#!',
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

        // FIX: create contact under same account
        Contact con = new Contact(
            FirstName = 'Test',
            LastName = 'Contact',
            AccountId = acc.Id,
            Email = 'test@test.com'
        );
        insert con;

        Id stdPbId = Test.getStandardPricebookId();

        Opportunity opp = new Opportunity(
            Name = 'Test',
            AccountId = acc.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today(),
            Pricebook2Id = stdPbId,
            Contact__c = con.Id
        );
        insert opp;

        Quote q = new Quote(
            Name = 'Test',
            QuoteAccountId = acc.Id,
            OpportunityId = opp.Id,
            Pricebook2Id = stdPbId,
            Status = 'Draft'
        );
        insert q;

        Test.setCurrentPage(Page.QuotePreview);
        ApexPages.currentPage().getParameters().put('id', q.Id);

        Test.startTest();
        QuotePDFController ctrl = new QuotePDFController();
        String fileName = ctrl.getPreviewName();
        Test.stopTest();

        System.assert(!fileName.contains('@'));
        System.assert(!fileName.contains('#'));
        System.assert(!fileName.contains('!'));
    }

    // --- getEmailWrappedForColumn() ---

    @isTest
    static void testGetEmailWrappedForColumn_NoQuote() {
        QuotePDFController ctrl = new QuotePDFController();
        ctrl.q = null;

        System.assertEquals('', ctrl.getEmailWrappedForColumn());
    }

    @isTest
    static void testGetEmailWrappedForColumn_BlankEmail() {
        Test.setCurrentPage(Page.QuotePreview);
        ApexPages.currentPage().getParameters().put('id', getQuoteId());

        QuotePDFController ctrl = new QuotePDFController();

        ctrl.q.Email = null;
        System.assertEquals('', ctrl.getEmailWrappedForColumn());

        ctrl.q.Email = '   ';
        System.assertEquals('', ctrl.getEmailWrappedForColumn());
    }

    @isTest
    static void testGetEmailWrappedForColumn_NoAtSign() {
        Test.setCurrentPage(Page.QuotePreview);
        ApexPages.currentPage().getParameters().put('id', getQuoteId());

        QuotePDFController ctrl = new QuotePDFController();
        ctrl.q.Email = 'noatsign';

        System.assertEquals('noatsign', ctrl.getEmailWrappedForColumn());
    }

    @isTest
    static void testGetEmailWrappedForColumn_ShortBeforeAt_NoBreak() {
        Test.setCurrentPage(Page.QuotePreview);
        ApexPages.currentPage().getParameters().put('id', getQuoteId());

        QuotePDFController ctrl = new QuotePDFController();
        ctrl.q.Email = 'short@example.com';

        System.assertEquals('short@example.com', ctrl.getEmailWrappedForColumn());
    }

    @isTest
    static void testGetEmailWrappedForColumn_LongBeforeAt_BreakAfterAt() {
        Test.setCurrentPage(Page.QuotePreview);
        ApexPages.currentPage().getParameters().put('id', getQuoteId());

        QuotePDFController ctrl = new QuotePDFController();

        // >22 chars before @ triggers line break
        ctrl.q.Email = 'verylonglocalpartname23@example.com';

        String result = ctrl.getEmailWrappedForColumn();

        System.assert(result.contains('<br/>'));
        System.assert(result.startsWith('verylonglocalpartname23@'));
        System.assert(result.endsWith('example.com'));
    }
}