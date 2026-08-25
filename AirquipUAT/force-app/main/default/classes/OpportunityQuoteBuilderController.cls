/**
 * Supports the opportunityQuoteBuilder LWC: resolve Account/Contact/Case from a source record,
 * search PricebookEntry rows, then create (or attach to) an Opportunity, a Quote, and
 * QuoteLineItem / OpportunityLineItem rows in one transaction — aligned with patterns in
 * Schedule_Job_From_Case (Opportunity + Quote + line items).
 */
public with sharing class OpportunityQuoteBuilderController {
    private static final String TARGET_STAGE = 'Solution Proposed / Quote Sent';

    public class SourceContext {
        @AuraEnabled public Id accountId;
        @AuraEnabled public String accountName;
        @AuraEnabled public Id contactId;
        @AuraEnabled public String contactName;
        @AuraEnabled public Id caseId;
        @AuraEnabled public Id pricebookId;
        @AuraEnabled public Boolean useExistingOpportunity;
        @AuraEnabled public Id existingOpportunityId;
        @AuraEnabled public String existingOpportunityName;
        @AuraEnabled public String suggestedOpportunityName;
        @AuraEnabled public String suggestedQuoteName;
    }

    public class LineInput {
        @AuraEnabled public Id pricebookEntryId { get; set; }
        @AuraEnabled public Decimal quantity { get; set; }
        @AuraEnabled public Decimal unitPrice { get; set; }
        @AuraEnabled public String description { get; set; }
        @AuraEnabled public Boolean includeInQuote { get; set; }
    }

    public class PbeOption {
        @AuraEnabled public Id id;
        @AuraEnabled public Id productId;
        @AuraEnabled public String productName;
        @AuraEnabled public String productCode;
        @AuraEnabled public String description;
        @AuraEnabled public Decimal listPrice;
        @AuraEnabled public Decimal cost;
    }

    public class AccountOption {
        @AuraEnabled public Id accountId;
        @AuraEnabled public String accountName;
        @AuraEnabled public String accountNumber;
        @AuraEnabled public String label;
    }

    public class ContactOption {
        @AuraEnabled public Id contactId;
        @AuraEnabled public String name;
        @AuraEnabled public String email;
        @AuraEnabled public String phone;
        @AuraEnabled public String label;
    }

    public class OpportunityOption {
        @AuraEnabled public Id opportunityId;
        @AuraEnabled public String name;
        @AuraEnabled public String stageName;
        @AuraEnabled public Date closeDate;
        @AuraEnabled public Id pricebookId;
        @AuraEnabled public String label;
    }

    public class CreateResult {
        @AuraEnabled public Id opportunityId;
        @AuraEnabled public Id quoteId;
    }

    @AuraEnabled(cacheable = false)
    public static SourceContext getSourceContext(Id sourceRecordId) {
        SourceContext ctx = new SourceContext();
        ctx.pricebookId = resolveActivePricebookId();
        ctx.useExistingOpportunity = false;
        if (sourceRecordId == null) {
            return ctx;
        }

        ctx.useExistingOpportunity = (sourceRecordId.getSobjectType() == Opportunity.SObjectType);
        if (ctx.useExistingOpportunity) {
            ctx.existingOpportunityId = sourceRecordId;
        }

        Schema.SObjectType typ = sourceRecordId.getSobjectType();
        String objectApi = typ.getDescribe().getName();
        Map<String, Schema.SObjectField> fm = typ.getDescribe().fields.getMap();

        List<String> selectFields = new List<String>{ 'Id' };
        if (fm.containsKey('accountid')) {
            selectFields.add('AccountId');
        }
        if (fm.containsKey('contactid')) {
            selectFields.add('ContactId');
        }
        if (fm.containsKey('contact__c')) {
            selectFields.add('Contact__c');
        }
        if (fm.containsKey('casenumber')) {
            selectFields.add('CaseNumber');
        }
        if (objectApi == 'Case' && fm.containsKey('subject')) {
            selectFields.add('Subject');
        }
        if (fm.containsKey('name') && objectApi != 'Case') {
            selectFields.add('Name');
        }
        if (objectApi == 'Opportunity' && fm.containsKey('pricebook2id')) {
            selectFields.add('Pricebook2Id');
        }
        if (objectApi == 'Quote') {
            if (fm.containsKey('quoteaccountid')) {
                selectFields.add('QuoteAccountId');
            }
            if (fm.containsKey('pricebook2id')) {
                selectFields.add('Pricebook2Id');
            }
            if (fm.containsKey('opportunityid')) {
                selectFields.add('OpportunityId');
            }
            if (fieldExists(Quote.SObjectType, 'Case__c')) {
                selectFields.add('Case__c');
            }
        }

        String soql =
            'SELECT ' +
            String.join(selectFields, ',') +
            ' FROM ' +
            objectApi +
            ' WHERE Id = :sourceRecordId LIMIT 1';

        SObject rec = Database.query(soql);

        if (objectApi == 'Quote') {
            Id quoteAcct = null;
            if (fm.containsKey('quoteaccountid')) {
                quoteAcct = (Id) rec.get('QuoteAccountId');
            }
            if (quoteAcct == null && fm.containsKey('accountid')) {
                quoteAcct = (Id) rec.get('AccountId');
            }
            ctx.accountId = quoteAcct;
            if (fm.containsKey('contactid')) {
                ctx.contactId = (Id) rec.get('ContactId');
            }
            if (fieldExists(Quote.SObjectType, 'Case__c')) {
                ctx.caseId = (Id) rec.get('Case__c');
            } else {
                ctx.caseId = null;
            }
            // Product search uses the org standard active price book (same as Opportunity price book default).
            ctx.pricebookId = resolveActivePricebookId();
            String qn = fm.containsKey('name') ? (String) rec.get('Name') : null;
            ctx.suggestedQuoteName = String.isBlank(qn) ? 'New Quote' : qn + ' — Lines';
            ctx.suggestedOpportunityName = ctx.suggestedQuoteName;
        } else if (objectApi == 'Account') {
            ctx.accountId = rec.Id;
            ctx.accountName = (String) rec.get('Name');
            ctx.contactId = null;
            ctx.caseId = null;
            String accName = (String) rec.get('Name');
            ctx.suggestedOpportunityName = buildSuggestedOppName(accName, null);
            ctx.suggestedQuoteName = buildSuggestedQuoteName(accName, null);
        } else if (ctx.useExistingOpportunity) {
            ctx.accountId = (Id) rec.get('AccountId');
            ctx.contactId = null;
            ctx.caseId = null;
            Id oppPb = (Id) rec.get('Pricebook2Id');
            if (oppPb != null) {
                ctx.pricebookId = oppPb;
            }
            String oname = (String) rec.get('Name');
            ctx.existingOpportunityName = oname;
            ctx.suggestedOpportunityName = oname;
            ctx.suggestedQuoteName = (oname != null ? oname : 'Quote') + ' — Quote';
        } else {
            ctx.accountId = (Id) rec.get('AccountId');
            if (fm.containsKey('contactid')) {
                ctx.contactId = (Id) rec.get('ContactId');
            }
            if (fm.containsKey('contact__c') && ctx.contactId == null) {
                ctx.contactId = (Id) rec.get('Contact__c');
            }
            ctx.caseId = (objectApi == 'Case') ? rec.Id : null;

            String caseNumber = fm.containsKey('casenumber') ? (String) rec.get('CaseNumber') : null;
            String fallbackName;
            if (objectApi == 'Case' && fm.containsKey('subject')) {
                fallbackName = (String) rec.get('Subject');
            } else {
                fallbackName = fm.containsKey('name') ? (String) rec.get('Name') : null;
            }
            ctx.suggestedOpportunityName = buildSuggestedOppName(fallbackName, caseNumber);
            ctx.suggestedQuoteName = buildSuggestedQuoteName(fallbackName, caseNumber);
        }

        if (ctx.accountId == null && !ctx.useExistingOpportunity) {
            throw new AuraHandledException(
                'This record has no Account. For Case, Contact, or Order use a record with an Account. For Quote, set Quote Account (Quote Account field).'
            );
        }

        hydrateContextLabels(ctx);
        return ctx;
    }

    /**
     * Standard active price book first, then any active price book.
     * Exposed for the LWC so product search always has a price book even if getSourceContext fails.
     */
    @AuraEnabled(cacheable = false)
    public static Id getStandardActivePricebookId() {
        return resolveActivePricebookId();
    }

    @AuraEnabled(cacheable = true)
    public static List<AccountOption> searchAccounts(String keyword) {
        String likeStr = String.isBlank(keyword) ? '%' : '%' + keyword.trim() + '%';
        List<AccountOption> out = new List<AccountOption>();
        for (Account accountRecord : [
            SELECT Id, Name, AccountNumber
            FROM Account
            WHERE Name LIKE :likeStr
            ORDER BY Name
            LIMIT 25
        ]) {
            AccountOption row = new AccountOption();
            row.accountId = accountRecord.Id;
            row.accountName = accountRecord.Name;
            row.accountNumber = accountRecord.AccountNumber;
            row.label = buildAccountLabel(accountRecord.Name, accountRecord.AccountNumber);
            out.add(row);
        }
        return out;
    }

    @AuraEnabled(cacheable = true)
    public static List<ContactOption> getContacts(Id accountId) {
        List<ContactOption> out = new List<ContactOption>();
        if (accountId == null) {
            return out;
        }
        for (Contact contactRecord : [
            SELECT Id, Name, Email, Phone
            FROM Contact
            WHERE AccountId = :accountId
            ORDER BY LastModifiedDate DESC
            LIMIT 100
        ]) {
            out.add(buildContactOption(contactRecord));
        }
        return out;
    }

    @AuraEnabled(cacheable = false)
    public static ContactOption createContact(Id accountId, String contactName, String email, String phone) {
        try {
            if (accountId == null) {
                throw new AuraHandledException('Choose an Account before creating a Contact.');
            }
            if (String.isBlank(contactName)) {
                throw new AuraHandledException('Enter a Contact Name.');
            }

            List<Account> accounts = [
                SELECT Id
                FROM Account
                WHERE Id = :accountId
                LIMIT 1
            ];
            if (accounts.isEmpty()) {
                throw new AuraHandledException('The selected Account could not be found.');
            }

            String trimmedName = contactName.trim();
            Contact contactRecord = new Contact(AccountId = accountId);
            Integer splitAt = trimmedName.lastIndexOf(' ');
            if (splitAt > 0) {
                String firstName = trimmedName.substring(0, splitAt).trim();
                String lastName = trimmedName.substring(splitAt + 1).trim();
                if (String.isBlank(lastName)) {
                    contactRecord.LastName = firstName;
                } else {
                    contactRecord.FirstName = firstName;
                    contactRecord.LastName = lastName;
                }
            } else {
                contactRecord.LastName = trimmedName;
            }
            if (String.isNotBlank(email)) {
                contactRecord.Email = email.trim();
            }
            if (String.isNotBlank(phone)) {
                contactRecord.Phone = phone.trim();
            }
            insert contactRecord;

            contactRecord = [
                SELECT Id, Name, Email, Phone
                FROM Contact
                WHERE Id = :contactRecord.Id
                LIMIT 1
            ];
            return buildContactOption(contactRecord);
        } catch (AuraHandledException e) {
            throw e;
        } catch (DmlException e) {
            throw new AuraHandledException(formatDmlMessage(e));
        } catch (Exception e) {
            throw new AuraHandledException('Error creating contact: ' + e.getMessage());
        }
    }

    @AuraEnabled(cacheable = true)
    public static List<OpportunityOption> getOpportunities(Id accountId) {
        List<OpportunityOption> out = new List<OpportunityOption>();
        if (accountId == null) {
            return out;
        }
        for (Opportunity opportunityRecord : [
            SELECT Id, Name, StageName, CloseDate, Pricebook2Id
            FROM Opportunity
            WHERE AccountId = :accountId
            ORDER BY LastModifiedDate DESC
            LIMIT 100
        ]) {
            OpportunityOption row = new OpportunityOption();
            row.opportunityId = opportunityRecord.Id;
            row.name = opportunityRecord.Name;
            row.stageName = opportunityRecord.StageName;
            row.closeDate = opportunityRecord.CloseDate;
            row.pricebookId = opportunityRecord.Pricebook2Id;
            row.label = opportunityRecord.Name + (String.isNotBlank(opportunityRecord.StageName) ? ' - ' + opportunityRecord.StageName : '');
            out.add(row);
        }
        return out;
    }

    @AuraEnabled(cacheable = false)
    public static List<PbeOption> searchPricebookEntries(Id pricebookId, String searchTerm) {
        if (pricebookId == null) {
            throw new AuraHandledException('Price book is required.');
        }
        String likeStr = String.isBlank(searchTerm) ? '%' : '%' + searchTerm.trim() + '%';
        Boolean pbeHasCost = fieldExists(PricebookEntry.SObjectType, 'Cost__c');
        String selectFields = 'Id, Product2Id, UnitPrice, Product2.Name, Product2.ProductCode, Product2.Description';
        if (pbeHasCost) {
            selectFields += ', Cost__c';
        }
        List<PbeOption> out = new List<PbeOption>();

        if (String.isBlank(searchTerm)) {
            String soql =
                'SELECT ' +
                selectFields +
                ' FROM PricebookEntry WHERE Pricebook2Id = :pricebookId AND IsActive = TRUE AND Product2.IsActive = TRUE ORDER BY Product2.Name LIMIT 50';
            for (PricebookEntry pbe : Database.query(soql)) {
                PbeOption row = new PbeOption();
                row.id = pbe.Id;
                row.productId = pbe.Product2Id;
                row.productName = pbe.Product2.Name;
                row.productCode = pbe.Product2.ProductCode;
                row.description = pbe.Product2.Description;
                row.listPrice = pbe.UnitPrice;
                row.cost = pbeHasCost ? (Decimal) pbe.get('Cost__c') : null;
                out.add(row);
            }
            return out;
        }

        Set<Id> matchedEntryIds = new Set<Id>();
        String nameCodeSoql =
            'SELECT ' +
            selectFields +
            ' FROM PricebookEntry WHERE Pricebook2Id = :pricebookId AND IsActive = TRUE AND Product2.IsActive = TRUE AND (Product2.Name LIKE :likeStr OR Product2.ProductCode LIKE :likeStr) ORDER BY Product2.Name LIMIT 50';
        for (PricebookEntry pbe : Database.query(nameCodeSoql)) {
            matchedEntryIds.add(pbe.Id);
            PbeOption row = new PbeOption();
            row.id = pbe.Id;
            row.productId = pbe.Product2Id;
            row.productName = pbe.Product2.Name;
            row.productCode = pbe.Product2.ProductCode;
            row.description = pbe.Product2.Description;
            row.listPrice = pbe.UnitPrice;
            row.cost = pbeHasCost ? (Decimal) pbe.get('Cost__c') : null;
            out.add(row);
        }

        Integer remainingLimit = 50 - out.size();
        if (remainingLimit > 0) {
            String descriptionSoql =
                'SELECT ' +
                selectFields +
                ' FROM PricebookEntry WHERE Pricebook2Id = :pricebookId AND IsActive = TRUE AND Product2.IsActive = TRUE AND Product2.Description LIKE :likeStr AND Id NOT IN :matchedEntryIds ORDER BY Product2.Name LIMIT :remainingLimit';
            for (PricebookEntry pbe : Database.query(descriptionSoql)) {
                PbeOption row = new PbeOption();
                row.id = pbe.Id;
                row.productId = pbe.Product2Id;
                row.productName = pbe.Product2.Name;
                row.productCode = pbe.Product2.ProductCode;
                row.description = pbe.Product2.Description;
                row.listPrice = pbe.UnitPrice;
                row.cost = pbeHasCost ? (Decimal) pbe.get('Cost__c') : null;
                out.add(row);
            }
        }
        return out;
    }

    @AuraEnabled
    public static CreateResult createOpportunityQuoteAndLines(
        Id sourceRecordId,
        Id accountId,
        Id contactId,
        Id existingOpportunityId,
        String opportunityName,
        String quoteName,
        Date quoteExpirationDate,
        String description,
        List<LineInput> lines
    ) {
        if (lines == null || lines.isEmpty()) {
            throw new AuraHandledException('Add at least one line item before saving.');
        }
        if (existingOpportunityId == null && String.isBlank(opportunityName)) {
            throw new AuraHandledException('Opportunity name is required.');
        }
        if (String.isBlank(quoteName)) {
            throw new AuraHandledException('Quote name is required.');
        }

        SourceContext ctx = getSourceContext(sourceRecordId);
        if (accountId == null) {
            accountId = ctx.accountId;
        }
        if (contactId == null) {
            contactId = ctx.contactId;
        }
        if (existingOpportunityId == null && ctx.useExistingOpportunity) {
            existingOpportunityId = ctx.existingOpportunityId;
        }
        if (accountId == null) {
            throw new AuraHandledException('Account is required.');
        }

        validateContactAccount(contactId, accountId);
        Opportunity existingOpportunity = existingOpportunityId != null
            ? loadAndValidateOpportunity(existingOpportunityId, accountId)
            : null;

        Id pricebookId = existingOpportunity != null && existingOpportunity.Pricebook2Id != null
            ? existingOpportunity.Pricebook2Id
            : ctx.pricebookId;
        if (pricebookId == null) {
            pricebookId = resolveActivePricebookId();
        }
        Id caseId = ctx.caseId;

        Savepoint sp = Database.setSavepoint();
        try {
            Id opportunityId;
            if (existingOpportunity != null) {
                opportunityId = existingOpportunity.Id;
                if (existingOpportunity.Pricebook2Id == null) {
                    existingOpportunity.Pricebook2Id = pricebookId;
                    update existingOpportunity;
                }
            } else {
                Opportunity opp = new Opportunity();
                opp.Name = opportunityName.trim();
                opp.AccountId = accountId;
                opp.StageName = TARGET_STAGE;
                opp.CloseDate = quoteExpirationDate != null ? quoteExpirationDate : Date.today().addDays(30);
                opp.Pricebook2Id = pricebookId;
                if (contactId != null && fieldExists(Opportunity.SObjectType, 'Contact__c')) {
                    opp.put('Contact__c', contactId);
                }
                if (String.isNotBlank(description)) {
                    opp.Description = description;
                }
                if (caseId != null && fieldExists(Opportunity.SObjectType, 'Case__c')) {
                    opp.put('Case__c', caseId);
                }
                if (fieldExists(Opportunity.SObjectType, 'Quote_Created__c')) {
                    opp.put('Quote_Created__c', true);
                }
                insert opp;
                opportunityId = opp.Id;
            }

            Quote q = new Quote();
            q.Name = quoteName.trim();
            q.OpportunityId = opportunityId;
            q.Pricebook2Id = pricebookId;
            q.Status = 'Draft';
            q.QuoteAccountId = accountId;
            if (contactId != null) {
                q.ContactId = contactId;
            }
            if (String.isNotBlank(description)) {
                q.Description = description;
            }
            if (caseId != null && fieldExists(Quote.SObjectType, 'Case__c')) {
                q.put('Case__c', caseId);
            }
            if (quoteExpirationDate != null) {
                q.ExpirationDate = quoteExpirationDate;
            }
            insert q;

            List<QuoteLineItem> qlis = new List<QuoteLineItem>();
            List<OpportunityLineItem> olis = new List<OpportunityLineItem>();
            Boolean qliHasCost = fieldExists(QuoteLineItem.SObjectType, 'Cost__c');
            Boolean qliHasIncludeInQuote = fieldExists(QuoteLineItem.SObjectType, 'Include_In_Quote__c');
            Boolean qliHasLineItemDescription = fieldExists(QuoteLineItem.SObjectType, 'Line_Item_Description__c');
            Boolean pbeHasCost = fieldExists(PricebookEntry.SObjectType, 'Cost__c');
            Set<Id> pbeIds = new Set<Id>();
            for (LineInput li0 : lines) {
                if (li0.pricebookEntryId != null) {
                    pbeIds.add(li0.pricebookEntryId);
                }
            }
            Map<Id, PricebookEntry> costByPbe = new Map<Id, PricebookEntry>();
            if (qliHasCost && pbeHasCost && !pbeIds.isEmpty()) {
                costByPbe.putAll([SELECT Id, Cost__c FROM PricebookEntry WHERE Id IN :pbeIds]);
            }

            for (LineInput li : lines) {
                if (li.pricebookEntryId == null || li.quantity == null || li.quantity <= 0) {
                    continue;
                }
                Decimal unit = li.unitPrice != null ? li.unitPrice : 0;

                QuoteLineItem qli = new QuoteLineItem();
                qli.QuoteId = q.Id;
                qli.PricebookEntryId = li.pricebookEntryId;
                qli.Quantity = li.quantity;
                qli.UnitPrice = unit;
                if (String.isNotBlank(li.description)) {
                    qli.Description = li.description;
                    if (qliHasLineItemDescription) {
                        qli.put('Line_Item_Description__c', li.description);
                    }
                }
                if (qliHasIncludeInQuote) {
                    qli.put('Include_In_Quote__c', li.includeInQuote != false);
                }
                if (qliHasCost && pbeHasCost && costByPbe.containsKey(li.pricebookEntryId)) {
                    PricebookEntry pbeRow = costByPbe.get(li.pricebookEntryId);
                    if (pbeRow.Cost__c != null) {
                        qli.put('Cost__c', pbeRow.Cost__c);
                    }
                }
                qlis.add(qli);

                OpportunityLineItem oli = new OpportunityLineItem();
                oli.OpportunityId = opportunityId;
                oli.PricebookEntryId = li.pricebookEntryId;
                oli.Quantity = li.quantity;
                oli.UnitPrice = unit;
                if (String.isNotBlank(li.description)) {
                    oli.Description = li.description;
                }
                olis.add(oli);
            }

            if (qlis.isEmpty()) {
                throw new AuraHandledException('Each line needs a product, quantity greater than zero, and a unit price.');
            }

            insert qlis;
            insert olis;

            CreateResult res = new CreateResult();
            res.opportunityId = opportunityId;
            res.quoteId = q.Id;
            return res;
        } catch (Exception e) {
            Database.rollback(sp);
            throw new AuraHandledException(e.getMessage());
        }
    }

    private static Boolean fieldExists(Schema.SObjectType typ, String fieldApi) {
        return typ.getDescribe().fields.getMap().containsKey(fieldApi.toLowerCase());
    }

    private static void validateContactAccount(Id contactId, Id accountId) {
        if (contactId == null) {
            return;
        }
        Contact contactRecord = [
            SELECT Id, AccountId
            FROM Contact
            WHERE Id = :contactId
            LIMIT 1
        ];
        if (contactRecord.AccountId != accountId) {
            throw new AuraHandledException('Selected Contact must belong to the selected Account.');
        }
    }

    private static Opportunity loadAndValidateOpportunity(Id opportunityId, Id accountId) {
        Opportunity opportunityRecord = [
            SELECT Id, AccountId, Pricebook2Id
            FROM Opportunity
            WHERE Id = :opportunityId
            LIMIT 1
        ];
        if (opportunityRecord.AccountId != accountId) {
            throw new AuraHandledException('Selected Opportunity must belong to the selected Account.');
        }
        return opportunityRecord;
    }

    private static void hydrateContextLabels(SourceContext ctx) {
        if (ctx == null) {
            return;
        }
        if (ctx.accountId != null && String.isBlank(ctx.accountName)) {
            Account accountRecord = [
                SELECT Id, Name
                FROM Account
                WHERE Id = :ctx.accountId
                LIMIT 1
            ];
            ctx.accountName = accountRecord.Name;
        }
        if (ctx.contactId != null && String.isBlank(ctx.contactName)) {
            Contact contactRecord = [
                SELECT Id, Name
                FROM Contact
                WHERE Id = :ctx.contactId
                LIMIT 1
            ];
            ctx.contactName = contactRecord.Name;
        }
    }

    private static String buildAccountLabel(String name, String accountNumber) {
        return name + (String.isNotBlank(accountNumber) ? ' - ' + accountNumber : '');
    }

    private static ContactOption buildContactOption(Contact contactRecord) {
        ContactOption row = new ContactOption();
        row.contactId = contactRecord.Id;
        row.name = contactRecord.Name;
        row.email = contactRecord.Email;
        row.phone = contactRecord.Phone;
        row.label = contactRecord.Name + (String.isNotBlank(contactRecord.Email) ? ' - ' + contactRecord.Email : '');
        return row;
    }

    private static String formatDmlMessage(DmlException e) {
        if (e == null) {
            return 'Unable to create contact.';
        }
        if (e.getNumDml() > 0 && String.isNotBlank(e.getDmlMessage(0))) {
            return e.getDmlMessage(0);
        }
        return String.isNotBlank(e.getMessage()) ? e.getMessage() : 'Unable to create contact.';
    }

    /**
     * Price book lookup without row-level sharing so profiles without Pricebook2 read access
     * can still resolve the org standard / active catalog for quoting.
     */
    private without sharing class PricebookReadHelper {
        Id resolveActive() {
            List<Pricebook2> std = [
                SELECT Id
                FROM Pricebook2
                WHERE IsActive = TRUE AND IsStandard = TRUE
                LIMIT 1
            ];
            if (!std.isEmpty()) {
                return std[0].Id;
            }
            List<Pricebook2> anyPb = [
                SELECT Id
                FROM Pricebook2
                WHERE IsActive = TRUE
                ORDER BY CreatedDate
                LIMIT 1
            ];
            if (anyPb.isEmpty()) {
                throw new AuraHandledException(
                    'No active price book was found. Activate the Standard Price Book (or any price book) and try again.'
                );
            }
            return anyPb[0].Id;
        }
    }

    private static Id resolveActivePricebookId() {
        return new PricebookReadHelper().resolveActive();
    }

    private static String firstOpenOpportunityStage() {
        for (Schema.PicklistEntry pe : Opportunity.StageName.getDescribe().getPicklistValues()) {
            if (pe.isActive()) {
                return pe.getValue();
            }
        }
        return 'Prospecting';
    }

    private static String buildSuggestedOppName(String nameFallback, String caseNumber) {
        String defaultCloseDate = formatDateForName(Date.today().addDays(30));
        if (!String.isBlank(caseNumber)) {
            return 'Case ' + caseNumber + ' - ' + defaultCloseDate;
        }
        if (!String.isBlank(nameFallback)) {
            return nameFallback + ' - ' + defaultCloseDate;
        }
        return 'New Opportunity - ' + defaultCloseDate;
    }

    private static String formatDateForName(Date value) {
        if (value == null) {
            return '';
        }
        return String.valueOf(value.month()).leftPad(2, '0') + '/' +
            String.valueOf(value.day()).leftPad(2, '0') + '/' +
            String.valueOf(value.year());
    }

    private static String buildSuggestedQuoteName(String nameFallback, String caseNumber) {
        if (!String.isBlank(caseNumber)) {
            return caseNumber + ' Quote';
        }
        if (!String.isBlank(nameFallback)) {
            return nameFallback + ' Quote';
        }
        return 'New Quote';
    }
}