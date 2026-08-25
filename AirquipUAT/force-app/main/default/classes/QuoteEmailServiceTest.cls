@isTest
private class QuoteEmailServiceTest {

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

    static Quote getQuote() {
        return [SELECT Id FROM Quote LIMIT 1];
    }

    @isTest
    static void testGetFromAddresses() {
        List<String> result = QuoteEmailService.getFromAddresses();
        System.assert(result.size() >= 1);
        System.assertEquals(UserInfo.getUserEmail(), result[0]);
    }

    @isTest
    static void testGetQuoteEmailTemplate_ReturnsExpectedKeys() {
        Map<String, String> result = QuoteEmailService.getQuoteEmailTemplate(getQuote().Id);

        System.assert(result.containsKey('subject'));
        System.assert(result.containsKey('body'));
    }

    @isTest
    static void testSendQuoteEmail_NoAttachment() {
        Test.startTest();
        QuoteEmailService.sendQuoteEmail(
            getQuote().Id,
            UserInfo.getUserEmail(),
            'to@example.com',
            '',
            '',
            'Subject',
            '<p>Body</p>',
            null
        );
        Test.stopTest();
    }

    @isTest
    static void testSendQuoteEmail_WithAttachment() {
        List<Map<String, Object>> atts = new List<Map<String, Object>>{
            new Map<String, Object>{
                'content' => EncodingUtil.base64Encode(Blob.valueOf('data')),
                'title' => 'File_v1'
            }
        };

        Test.startTest();
        QuoteEmailService.sendQuoteEmail(
            getQuote().Id,
            UserInfo.getUserEmail(),
            'to@example.com',
            '',
            '',
            'Subject',
            '<p>Body</p>',
            atts
        );
        Test.stopTest();
    }

    @isTest
    static void testSendQuoteEmail_SkipsAttachmentWithoutContentKey() {
        Test.startTest();
        QuoteEmailService.sendQuoteEmail(
            getQuote().Id,
            UserInfo.getUserEmail(),
            'to@example.com',
            '',
            '',
            'Subject',
            '<p>Body</p>',
            new List<Map<String, Object>>{ new Map<String, Object>{ 'title' => 'OnlyTitle' } }
        );
        Test.stopTest();
    }

    @isTest
    static void testSendQuoteEmail_ThrowsOnError() {
        Boolean threw = false;
        try {
            Test.startTest();
            QuoteEmailService.sendQuoteEmail(
                getQuote().Id,
                '',
                '',
                '',
                '',
                '',
                '',
                null
            );
            Test.stopTest();
        } catch (Exception e) {
            threw = true;
        }
        System.assert(threw);
    }

    @isTest
    static void testSearchEmails_Match() {
        List<Map<String, String>> results = QuoteEmailService.searchEmails('Jane');
        System.assert(results.size() > 0);
        System.assertEquals('jane.doe@example.com', results[0].get('Email'));
    }

    @isTest
    static void testSearchEmails_BlankOrNull() {
        System.assertEquals(0, QuoteEmailService.searchEmails('').size());
        System.assertEquals(0, QuoteEmailService.searchEmails(null).size());
    }

    @isTest
    static void testGetLatestQuoteFile_NoDoc() {
        System.assertEquals(null, QuoteEmailService.getLatestQuoteFile(getQuote().Id));
    }
}