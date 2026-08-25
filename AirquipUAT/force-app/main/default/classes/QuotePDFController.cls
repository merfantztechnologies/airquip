public with sharing class QuotePDFController {

    public Quote q {get;set;}
    public List<QuoteLineItem> lines {get;set;}
    public List<LineItemWrapper> lineItemWrappers {get;set;}
    public String ownerCompanyName {get;set;}
    public String qualificationsHtml { get; set; }
	public String scopeOfWorkHtml { get; set; }

    public class LineItemWrapper {
        public Decimal quantity {get; set;}
        public String wrappedProductName {get; set;}
        public String lineItemDescription {get; set;}
        public Decimal unitPrice {get; set;}
        public Decimal totalPrice {get; set;}
        public String formattedUnitPrice {get; set;}
        public String formattedTotalPrice {get; set;}

        public LineItemWrapper(QuoteLineItem item) {
            quantity = item.Quantity;
            unitPrice = item.UnitPrice;
            totalPrice = item.TotalPrice;
            formattedUnitPrice = QuotePDFController.formatCurrencyForPdfWrap(unitPrice);
            formattedTotalPrice = QuotePDFController.formatCurrencyForPdfWrap(totalPrice);
            lineItemDescription = item.Line_Item_Description__c;
            wrappedProductName = String.isBlank(item.Product2?.Name)
                ? ''
                : wrapAtWordBoundary(item.Product2.Name, 16);
        }

        private String wrapAtWordBoundary(String name, Integer maxChars) {
            if (String.isBlank(name)) {
                return '';
            }

            String result = '';
            String remaining = name;

            while (remaining.length() > 0) {
                if (remaining.length() <= maxChars) {
                    // Escape user text so "<00504-054" renders as text; keep <br/> unescaped for PDF wrapping
                    result += remaining.escapeHtml4();
                    break;
                }

                Integer breakIndex = -1;
                for (Integer i = Math.min(maxChars, remaining.length() - 1); i >= 1; i--) {
                    String ch = remaining.substring(i - 1, i);
                    if (ch == '@' || ch == '-' || ch == '/' || ch == ' ') {
                        breakIndex = i;
                        break;
                    }
                }

                if (breakIndex == -1) {
                    result += remaining.substring(0, maxChars).escapeHtml4() + '<br/>';
                    remaining = remaining.substring(maxChars);
                } else {
                    result += remaining.substring(0, breakIndex).escapeHtml4() + '<br/>';
                    remaining = remaining.substring(breakIndex);
                    if (remaining.startsWith(' ')) {
                        remaining = remaining.substring(1);
                    }
                }
            }

            return result;
        }
    }

    public QuotePDFController(){

        try {
            Id quoteId = ApexPages.currentPage() != null && ApexPages.currentPage().getParameters() != null
                ? ApexPages.currentPage().getParameters().get('id')
                : null;

            if (quoteId == null) return;

            List<Quote> qList = [
                SELECT Id, Name, QuoteNumber, CreatedDate, ExpirationDate, Grand_Total__c,
                       Email, Company_Phone__c, OwnerId, Owner.Name, Owner.Email, Owner.Phone,
                       Contact.Name, Account.Account_Number__c, Account.Name,
                       BillingStreet, BillingCity, BillingState, BillingPostalCode, BillingCountry,
                       ShippingStreet, ShippingCity, ShippingState, ShippingPostalCode, ShippingCountry,
                       Sub_Total__c, TotalPrice, ShippingHandling, Tax, Scope_of_Work__c,Qualifications__c
                FROM Quote
                WHERE Id = :quoteId
                LIMIT 1
            ];

            if (!qList.isEmpty()) {
                q = qList[0];
                if (q.OwnerId != null && String.valueOf(q.OwnerId).startsWith('005')) {
                    List<User> owners = [
                        SELECT CompanyName
                        FROM User
                        WHERE Id = :q.OwnerId
                        LIMIT 1
                    ];
                    if (!owners.isEmpty()) {
                        ownerCompanyName = owners[0].CompanyName;
                    }
                }
            } else if (quoteId != null) {
                throw new AuraHandledException('Quote not found or you do not have access to this quote.');
            }

            lines = [
                SELECT Quantity, UnitPrice, TotalPrice,
                       Product2.Name, Product2.ProductCode, Description, Line_Item_Description__c,Total_Price__c
                FROM QuoteLineItem
                WHERE QuoteId = :quoteId AND Include_In_Quote__c = TRUE ORDER BY SortOrder
            ];

            lineItemWrappers = new List<LineItemWrapper>();
            for (QuoteLineItem item : lines) {
                lineItemWrappers.add(new LineItemWrapper(item));
            }
            
        } catch (Exception e) {
            System.debug('QuotePDFController Error: ' + e.getMessage());
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'Error loading quote: ' + e.getMessage()));
        }
        
        qualificationsHtml = q != null && q.Qualifications__c != null
            ? q.Qualifications__c.replace('\n', '<br/>')
            : '';

        scopeOfWorkHtml = q != null && q.Scope_of_Work__c != null
            ? q.Scope_of_Work__c.replace('\n', '<br/>')
            : '';
    }

    // Left-column email: break after @ only if part before @ is more than 25 characters
    public String getEmailWrappedForColumn() {
        if (q == null || String.isBlank(q.Email)) return '';
        String e = q.Email.trim();
        Integer atIdx = e.indexOf('@');
        if (atIdx < 0) return e;
        if (atIdx <= 22) return e;
        String beforeAt = e.substring(0, atIdx + 1);
        String afterAt = e.substring(atIdx + 1);
        return beforeAt + '<br/>' + afterAt;
    }

    public static String formatCurrencyForPdfWrap(Decimal amount) {
        Decimal safeAmount = amount == null ? 0 : amount;
        String formattedNumber = safeAmount.setScale(2).format();
        if (!formattedNumber.contains('.')) {
            formattedNumber += '.00';
        } else if (formattedNumber.substringAfter('.').length() == 1) {
            formattedNumber += '0';
        }
        String formatted = '$' + formattedNumber;
        return wrapCurrencyAtComma(formatted, 17);
    }

    private static String wrapCurrencyAtComma(String value, Integer maxChars) {
        if (String.isBlank(value) || value.length() <= maxChars) {
            return value;
        }

        List<String> parts = value.split(',');
        String result = '';
        String line = '';

        for (Integer i = 0; i < parts.size(); i++) {
            String segment = i == 0 ? parts[i] : ',' + parts[i];
            if (line.length() > 0 && (line.length() + segment.length()) > maxChars) {
                result += line + '<br/>';
                line = segment.startsWith(',') ? segment.substring(1) : segment;
            } else {
                line += segment;
            }
        }

        return result + line;
    }
    
    

    // ✅ Getter for Preview File Name
    public String getPreviewName(){

        if(q == null) return 'Quote.pdf';

        String accName = (q.Account != null && q.Account.Name != null)
            ? q.Account.Name.replaceAll('[^a-zA-Z0-9]', '_')
            : 'Account';

        String quoteNum = String.isNotBlank(q.QuoteNumber)
            ? q.QuoteNumber
            : 'Quote';

        String today = DateTime.now().format('MM-dd-yyyy');

        return 'Airquip_' + accName + '_' + quoteNum + '_' + today + '.pdf';
    }
}