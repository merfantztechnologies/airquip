public class QuoteTriggerHandler {

    public static void processApprovedQuotes(List<Quote> quoteList) {

        Set<Id> quoteIds = new Set<Id>();
        Set<Id> oppIds   = new Set<Id>();

        for (Quote q : quoteList) {
            quoteIds.add(q.Id);
            if (q.OpportunityId != null) {
                oppIds.add(q.OpportunityId);
            }
        }

        // =========================================
        // Prevent Duplicate Orders
        // =========================================

        Set<Id> processedQuoteIds = new Set<Id>();

        for (Order o : [
            SELECT Id, QuoteId
            FROM Order
            WHERE QuoteId IN :quoteIds
        ]) {
            processedQuoteIds.add(o.QuoteId);
        }

        // =========================================
        // Get Quote Details
        // =========================================

        Map<Id, Quote> quoteMap = new Map<Id, Quote>([
            SELECT Id,
                   Name,
                   AccountId,
                   OpportunityId,
                   Description,
                   Pricebook2Id,
                   ContactId,
                   Tax,
                   Discount,
                   BillingStreet,
                   BillingCity,
                   BillingState,
                   BillingPostalCode,
                   BillingCountry,
                   Account.Terms__c
            FROM Quote
            WHERE Id IN :quoteIds
        ]);

        // Map QuoteId -> Trigger.new Quote (only these allow addError)
        Map<Id, Quote> triggerQuoteMap = new Map<Id, Quote>();
        for (Quote q : quoteList) {
            triggerQuoteMap.put(q.Id, q);
        }

        // Map OpportunityId -> Quote (to trace errors back to the right Quote)
        Map<Id, Quote> oppToTriggerQuoteMap = new Map<Id, Quote>();
        for (Quote q : quoteList) {
            if (q.OpportunityId != null) {
                oppToTriggerQuoteMap.put(q.OpportunityId, q);
            }
        }

        // =========================================
        // Update Opportunities to Closed Won
        // =========================================

        List<Opportunity> oppsToUpdate = new List<Opportunity>();

        for (Opportunity opp : [
            SELECT Id, StageName
            FROM Opportunity
            WHERE Id IN :oppIds
        ]) {
            if (opp.StageName != 'Closed Won') {
                opp.StageName = 'Closed Won';
                oppsToUpdate.add(opp);
            }
        }

        if (!oppsToUpdate.isEmpty()) {
            List<Database.SaveResult> oppResults = Database.update(oppsToUpdate, false);

            for (Integer i = 0; i < oppResults.size(); i++) {
                Database.SaveResult sr = oppResults[i];
                if (!sr.isSuccess()) {
                    Quote triggerQuote = oppToTriggerQuoteMap.get(oppsToUpdate[i].Id);
                    for (Database.Error err : sr.getErrors()) {
                        if (triggerQuote != null) {
                            if (err.getStatusCode() == StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION
                                || err.getStatusCode() == StatusCode.REQUIRED_FIELD_MISSING
                                || err.getStatusCode() == StatusCode.FIELD_INTEGRITY_EXCEPTION) {
                                triggerQuote.addError(err.getMessage());
                            } else {
                                triggerQuote.addError('Opportunity could not be updated. Please contact your administrator.');
                            }
                        }
                    }
                }
            }
        }

        // =========================================
        // Create Orders
        // =========================================

        List<Order> orders        = new List<Order>();
        List<Quote> orderedQuotes = new List<Quote>();

        for (Quote q : quoteMap.values()) {
            if (processedQuoteIds.contains(q.Id)) {
                continue;
            }

            Order ord = new Order();
            ord.AccountId         = q.AccountId;
            ord.OpportunityId     = q.OpportunityId;
            ord.QuoteId           = q.Id;
            ord.Pricebook2Id      = q.Pricebook2Id;
            ord.Payment_Terms__c  = q.Account.Terms__c;
            ord.EffectiveDate     = Date.today();
            ord.Status            = 'Draft';
            ord.Description       = q.Description;
            ord.Tax__c            = q.Tax;
            ord.Discount__c       = q.Discount;
            ord.BillingStreet     = q.BillingStreet;
            ord.BillingCity       = q.BillingCity;
            ord.BillingState      = q.BillingState;
            ord.BillingPostalCode = q.BillingPostalCode;
            ord.BillingCountry    = q.BillingCountry;

            if (q.ContactId != null) {
                ord.Contact__c = q.ContactId;
            }

            orders.add(ord);
            orderedQuotes.add(q);
        }

        if (!orders.isEmpty()) {
            List<Database.SaveResult> orderResults = Database.insert(orders, false);

            List<Order> successOrders = new List<Order>();
            List<Quote> successQuotes = new List<Quote>();

            for (Integer i = 0; i < orderResults.size(); i++) {
                Database.SaveResult sr = orderResults[i];
                if (sr.isSuccess()) {
                    successOrders.add(orders[i]);
                    successQuotes.add(orderedQuotes[i]);
                } else {
                    // Use Trigger.new quote so addError() works
                    Quote triggerQuote = triggerQuoteMap.get(orderedQuotes[i].Id);
                    for (Database.Error err : sr.getErrors()) {
                        if (triggerQuote != null) {
                            if (err.getStatusCode() == StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION
                                || err.getStatusCode() == StatusCode.REQUIRED_FIELD_MISSING
                                || err.getStatusCode() == StatusCode.FIELD_INTEGRITY_EXCEPTION) {
                                triggerQuote.addError(err.getMessage());
                            } else {
                                 triggerQuote.addError('Order could not be created. Please contact your administrator.');
                            }
                        }
                    }
                }
            }

            orders        = successOrders;
            orderedQuotes = successQuotes;
        }

        // =========================================
        // Map Opportunity -> Order
        // =========================================

        Map<Id, Id> oppToOrderMap = new Map<Id, Id>();
        for (Order ord : orders) {
            oppToOrderMap.put(ord.OpportunityId, ord.Id);
        }

        // =========================================
        // Get Quote Line Items
        // =========================================

        List<QuoteLineItem> qliList = [
            SELECT Id,
                   QuoteId,
                   Quantity,
                   UnitPrice,
                   PricebookEntryId,
                   Quote.OpportunityId,
                   Line_Item_Description__c
            FROM QuoteLineItem
            WHERE QuoteId IN :quoteIds
        ];

        // =========================================
        // Create Order Items
        // =========================================

        List<OrderItem>     orderItems = new List<OrderItem>();
        List<QuoteLineItem> sourceQLIs = new List<QuoteLineItem>();

        for (QuoteLineItem qli : qliList) {
            Id orderId = oppToOrderMap.get(qli.Quote.OpportunityId);
            if (orderId == null) {
                continue;
            }

            OrderItem oi = new OrderItem();
            oi.OrderId             = orderId;
            oi.Quantity            = qli.Quantity;
            oi.UnitPrice           = qli.UnitPrice;
            oi.PricebookEntryId    = qli.PricebookEntryId;
            oi.Line_Description__c = qli.Line_Item_Description__c;
            oi.QuoteLineItemId  = qli.id;
            orderItems.add(oi);
            sourceQLIs.add(qli);
        }

        if (!orderItems.isEmpty()) {
            List<Database.SaveResult> itemResults = Database.insert(orderItems, false);

            for (Integer i = 0; i < itemResults.size(); i++) {
                Database.SaveResult sr = itemResults[i];
                if (!sr.isSuccess()) {
                    // Use Trigger.new quote so addError() works
                    Quote triggerQuote = triggerQuoteMap.get(sourceQLIs[i].QuoteId);
                    for (Database.Error err : sr.getErrors()) {
                        if (triggerQuote != null) {
                            if (err.getStatusCode() == StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION
                                || err.getStatusCode() == StatusCode.REQUIRED_FIELD_MISSING
                                || err.getStatusCode() == StatusCode.FIELD_INTEGRITY_EXCEPTION) {
                                triggerQuote.addError('Order line item error: ' + err.getMessage());
                            } else {
                                triggerQuote.addError('An order line item could not be created. Please contact your administrator.');
                            }
                        }
                    }
                }
            }
        }
    }
}