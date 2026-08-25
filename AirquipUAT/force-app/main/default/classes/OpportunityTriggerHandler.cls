public class OpportunityTriggerHandler {

    public static void createOrders(List<Opportunity> oppList){

        Set<Id> quoteIds = new Set<Id>();
        for(Opportunity o : oppList){
            quoteIds.add(o.SyncedQuoteId);
        }

        Map<Id, Quote> quoteMap = new Map<Id, Quote>(
            [SELECT Id, AccountId, Pricebook2Id, ContactId,Tax,Discount
             FROM Quote
             WHERE Id IN :quoteIds]
        );

        List<Order> orders = new List<Order>();

        for(Opportunity opp : oppList){

            Quote q = quoteMap.get(opp.SyncedQuoteId);

            Order ord = new Order();
            ord.AccountId = q.AccountId;
            ord.EffectiveDate = Date.today();
            ord.Status = 'Draft';
            ord.Pricebook2Id = q.Pricebook2Id;
            ord.OpportunityId = opp.Id;
            ord.QuoteId        = q.Id; 

            ord.Tax__c= q.Tax;
            ord.Discount__c = q.Discount;

            if(q.ContactId != null){
                    ord.Contact__c = q.ContactId;
               }
            
            orders.add(ord);
        }

        insert orders;

        // ===== Create Order Products from Quote Line Items =====

        Map<Id, Id> oppToOrderMap = new Map<Id, Id>();
        for(Order o : orders){
            oppToOrderMap.put(o.OpportunityId , o.Id);
        }

        List<QuoteLineItem> qliList = [
            SELECT Id, QuoteId, Quantity, UnitPrice, PricebookEntryId
            FROM QuoteLineItem
            WHERE QuoteId IN :quoteIds
        ];

        List<OrderItem> orderItems = new List<OrderItem>();

        for(QuoteLineItem qli : qliList){

            Id orderId = oppToOrderMap.get(
                [SELECT OpportunityId FROM Quote WHERE Id = :qli.QuoteId].OpportunityId
            );

            OrderItem oi = new OrderItem();
            oi.OrderId = orderId;
            oi.Quantity = qli.Quantity;
            oi.UnitPrice = qli.UnitPrice;
            oi.PricebookEntryId = qli.PricebookEntryId;

            orderItems.add(oi);
        }

        if(!orderItems.isEmpty()){
            insert orderItems;
        }
    }
}