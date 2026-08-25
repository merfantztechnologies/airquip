public class InvoiceLineItemTriggerHandler {

    // Prevents re-entrant calls while invoice tax DML is in progress (recursion only).
    // Does NOT permanently skip an invoice for the transaction, so later line-item
    // inserts/updates in the same transaction (e.g. consolidated invoices) still recalculate.
    private static Boolean isCalculatingTax = false;

    public static void calculateInvoiceTax(List<fax__Invoice_Line_Item__c> lines){

        if(isCalculatingTax){
            return;
        }

        if(lines == null || lines.isEmpty()){
            return;
        }

        Set<Id> invoiceIds = new Set<Id>();

        for(fax__Invoice_Line_Item__c li : lines){
            if(li.fax__Invoice__c != null){
                invoiceIds.add(li.fax__Invoice__c);
            }
        }

        if(invoiceIds.isEmpty()){
            return;
        }

        isCalculatingTax = true;

        try{

            // ===============================
            // STEP 1 → TAXABLE PRODUCT TOTAL
            // ===============================
            Map<Id, Decimal> taxableTotals = new Map<Id, Decimal>();

            for(AggregateResult ar : [
                SELECT fax__Invoice__c invId,
                       SUM(fax__Total_Amount_Excl_Tax__c) total
                FROM fax__Invoice_Line_Item__c
                WHERE fax__Invoice__c IN :invoiceIds
                AND fax__Product__r.Is_Taxable__c = TRUE AND Include_In_Invoice__c = TRUE
                GROUP BY fax__Invoice__c
            ]){
                taxableTotals.put(
                    (Id) ar.get('invId'),
                    (Decimal) ar.get('total')
                );
            }

            // ===============================
            // STEP 2 → GET INVOICES
            // ===============================
            Map<Id, fax__Invoice__c> invoiceMap = new Map<Id, fax__Invoice__c>([
                SELECT Id, Tax__c, Sub_Total_Tax_Product__c, fax__Site__c
                FROM fax__Invoice__c
                WHERE Id IN :invoiceIds
            ]);

            // ===============================
            // STEP 3 → GET ACCOUNT TAX GROUP
            // ===============================
            Set<Id> accountIds = new Set<Id>();
            for(fax__Invoice__c inv : invoiceMap.values()){
                if(inv.fax__Site__c != null){
                    accountIds.add(inv.fax__Site__c);
                }
            }

            Map<Id, Id> accountToTaxGroup = new Map<Id, Id>();

            for(Account acc : [
                SELECT Id, Tax_Group_Code__c
                FROM Account
                WHERE Id IN :accountIds
            ]){
                accountToTaxGroup.put(acc.Id, acc.Tax_Group_Code__c);
            }

            // ===============================
            // STEP 4 → GET TAX %
            // ===============================
            Set<Id> taxGroupIds = new Set<Id>();
            taxGroupIds.addAll(accountToTaxGroup.values());

            Map<Id, Decimal> taxGroupToPercent = new Map<Id, Decimal>();

            for(faxa__Tax__c tg : [
                SELECT Id, faxa__Percentage__c
                FROM faxa__Tax__c
                WHERE Id IN :taxGroupIds
            ]){
                taxGroupToPercent.put(tg.Id, tg.faxa__Percentage__c);
            }

            // ===============================
            // STEP 5 → CALCULATE TAX
            // ===============================
            List<fax__Invoice__c> invoicesToUpdate = new List<fax__Invoice__c>();

            for(fax__Invoice__c inv : invoiceMap.values()){

                Decimal taxableSubtotal = taxableTotals.containsKey(inv.Id)
                    ? taxableTotals.get(inv.Id)
                    : 0;

                Decimal taxPercent = 0;

                if(inv.fax__Site__c != null &&
                   accountToTaxGroup.containsKey(inv.fax__Site__c)){

                    Id tgId = accountToTaxGroup.get(inv.fax__Site__c);

                    if(taxGroupToPercent.containsKey(tgId)){
                        taxPercent = taxGroupToPercent.get(tgId);
                    }
                }

                Decimal newTaxAmount = (taxableSubtotal * taxPercent) / 100;

                Boolean needsUpdate = false;

                if(inv.Tax__c != taxPercent){
                    inv.Tax__c = taxPercent;
                    needsUpdate = true;
                }

                if(inv.Sub_Total_Tax_Product__c != newTaxAmount){
                    inv.Sub_Total_Tax_Product__c = newTaxAmount;
                    needsUpdate = true;
                }

                if(needsUpdate){
                    invoicesToUpdate.add(inv);
                }
            }

            if(!invoicesToUpdate.isEmpty()){
                update invoicesToUpdate;
            }

        }catch(Exception e){
            System.debug('Invoice Tax Error: ' + e.getMessage());
        }finally{
            isCalculatingTax = false;
        }
    }
}