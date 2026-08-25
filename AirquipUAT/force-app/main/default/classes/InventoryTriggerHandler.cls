/**
 * InventoryTriggerHandler
 * SMS ROW 9 — Low Stock Alert → SMS Inventory Manager
 *
 * Trigger: fax__Inventory__c AFTER UPDATE
 * Logic:   Fires when fax__Qty_in_Stock__c drops below fax__Minimum_Stock_Level__c
 * SMS To:  Phone__c on fax__Inventory__c
 *
 * Job No is fetched from the most recent fax__Part_Consumed__c
 * record linked to this Inventory item.
 *
 * Template: SMSTemplateService.LOW_STOCK_ALERT
 * Placeholders: {PartName} {Qty} {MinQty} {JobNo}
 */
public class InventoryTriggerHandler {

    public static void sendSMSLowStockAlert(
        List<fax__Inventory__c> newList,
        Map<Id, fax__Inventory__c> oldMap
    ) {
        // Step 1: Find inventory items that just dropped below minimum
        List<fax__Inventory__c> lowStockItems = new List<fax__Inventory__c>();
        Set<Id> lowStockIds = new Set<Id>();

        for (fax__Inventory__c inv : newList) {
            fax__Inventory__c oldInv = oldMap != null ? oldMap.get(inv.Id) : null;

            // Skip if no phone
            if (String.isBlank(inv.Phone__c)) continue;

            // Skip if stock or min level not defined
            if (inv.fax__Qty_in_Stock__c == null ||
                inv.fax__Minimum_Stock_Level__c == null) continue;

            Decimal currentStock = inv.fax__Qty_in_Stock__c;
            Decimal minStock     = inv.fax__Minimum_Stock_Level__c;

            // Only fire when stock JUST crossed below minimum
            // Was at/above min before AND now below min
            Boolean nowBelowMin = currentStock < minStock;
            Boolean wasBelowMin = false;

            if (oldInv != null && oldInv.fax__Qty_in_Stock__c != null) {
                wasBelowMin = oldInv.fax__Qty_in_Stock__c < minStock;
            }

            // Only fire when it JUST dropped below — not if already was below
            if (nowBelowMin && !wasBelowMin) {
                lowStockItems.add(inv);
                lowStockIds.add(inv.Id);
                System.debug('[InventoryTriggerHandler] Low stock: '
                    + inv.fax__Product_Name__c
                    + ' | Stock: ' + currentStock
                    + ' | Min: '   + minStock);
            }
        }

        if (lowStockItems.isEmpty()) return;

        // Step 2: Find the most recent Part Consumed record
        // linked to each low stock inventory item to get Job No
        Map<Id, String> inventoryToJobNo = new Map<Id, String>();

        List<fax__Part_Consumed__c> recentConsumed = [
            SELECT Id, fax__Inventory__c,
                   fax__Job__c, fax__Job__r.Name
            FROM   fax__Part_Consumed__c
            WHERE  fax__Inventory__c IN :lowStockIds
            AND    fax__Job__c != null
            ORDER BY CreatedDate DESC
        ];

        // Map each inventory to most recent job (first record per inventory
        // since ordered by CreatedDate DESC)
        for (fax__Part_Consumed__c pc : recentConsumed) {
            if (!inventoryToJobNo.containsKey(pc.fax__Inventory__c)) {
                inventoryToJobNo.put(
                    pc.fax__Inventory__c,
                    pc.fax__Job__r.Name
                );
            }
        }

        // Step 3: Send SMS for each low stock item
        for (fax__Inventory__c inv : lowStockItems) {
            Decimal currentStock = inv.fax__Qty_in_Stock__c;
            Decimal minStock     = inv.fax__Minimum_Stock_Level__c;

            // Get job no from most recent part consumed — fallback to N/A
            String jobNo = inventoryToJobNo.containsKey(inv.Id)
                ? inventoryToJobNo.get(inv.Id)
                : 'N/A';

            String msg = SMSTemplateService.build(
                SMSTemplateService.LOW_STOCK_ALERT,
                new Map<String, String>{
                    'PartName' => nvl(inv.fax__Product_Name__c),
                    'Qty'      => String.valueOf(currentStock.intValue()),
                    'MinQty'   => String.valueOf(minStock.intValue()),
                    'JobNo'    => jobNo
                }
            );

            if (String.isNotBlank(msg)) {
                RingCentralSMSService.sendSMS(inv.Phone__c, msg);
                System.debug('[InventoryTriggerHandler] ✅ Low stock SMS sent for: '
                    + inv.fax__Product_Name__c + ' | Job: ' + jobNo);
            }
        }
    }

    private static String nvl(String val) {
        return String.isNotBlank(val) ? val : '';
    }
}