/**
 * ProductRequestTriggerHandler
 *
 * ROW 7 — Trigger on fax__Product_Request_Item__c INSERT
 *   When a Part Request Item is created, SMS fires to Technician
 *   with actual Part Name + Qty from that item
 *
 * ROW 8 — Trigger on fax__Product_Request__c UPDATE
 *   When Product Request Status changes to 'Received'
 *   SMS fires with all child items summary
 *
 * Navigation:
 *   Item → fax__Product_Request__c → fax__Job__c → Service_Engineer__c → fax__Phone__c
 */
public class ProductRequestTriggerHandler {

    // ════════════════════════════════════════════════════════════════════════
    // ROW 7 — Called from ProductRequestItemTrigger (after insert)
    // Fires when a Part Request Item is created
    // Part Name + Qty taken directly from the inserted item
    // ════════════════════════════════════════════════════════════════════════
    public static void sendSMSPartRequestCreated(
        List<fax__Product_Request_Item__c> newItems
    ) {
        // Collect Product Request IDs
        Set<Id> prIds = new Set<Id>();
        for (fax__Product_Request_Item__c item : newItems) {
            if (item.fax__Product_Request__c != null)
                prIds.add(item.fax__Product_Request__c);
        }
        if (prIds.isEmpty()) return;

        // Query Product Requests → Job → Engineer
        Map<Id, fax__Product_Request__c> prMap = new Map<Id, fax__Product_Request__c>([
            SELECT Id, Name,
                   fax__Job__c,
                   fax__Job__r.Name,
                   fax__Job__r.Service_Engineer__c
            FROM   fax__Product_Request__c
            WHERE  Id IN :prIds
            AND    fax__Job__c != null
        ]);

        // Collect Engineer IDs
        Set<Id> engIds = new Set<Id>();
        for (fax__Product_Request__c pr : prMap.values()) {
            if (pr.fax__Job__r.Service_Engineer__c != null)
                engIds.add(pr.fax__Job__r.Service_Engineer__c);
        }
        if (engIds.isEmpty()) return;

        // Query Engineers
        Map<Id, fax__Service_Engineer__c> engMap = new Map<Id, fax__Service_Engineer__c>([
            SELECT Id, Name, fax__Phone__c
            FROM   fax__Service_Engineer__c
            WHERE  Id IN :engIds
        ]);

        // Send SMS for each inserted item
        for (fax__Product_Request_Item__c item : newItems) {
            fax__Product_Request__c pr = prMap.get(item.fax__Product_Request__c);
            if (pr == null) continue;

            fax__Service_Engineer__c eng =
                engMap.get(pr.fax__Job__r.Service_Engineer__c);
            if (eng == null || String.isBlank(eng.fax__Phone__c)) continue;

            String jobNo    = nvl(pr.fax__Job__r.Name);
            String partName = nvl(item.fax__Product_Name__c);
            String qty      = item.fax__Qty__c != null
                              ? String.valueOf(item.fax__Qty__c.intValue()) : '1';

            String msg = SMSTemplateService.build(
                SMSTemplateService.PART_REQUEST_CREATED,
                new Map<String, String>{
                    'EngineerName' => nvl(eng.Name),
                    'JobNo'        => jobNo,
                    'PartName'     => partName,
                    'Qty'          => qty
                }
            );
            if (String.isNotBlank(msg)) {
                RingCentralSMSService.sendSMS(eng.fax__Phone__c, msg);
                System.debug('[ProductRequestTriggerHandler] ✅ Row 7 sent | '
                    + 'Part: ' + partName + ' x' + qty
                    + ' | Engineer: ' + eng.Name);
            }
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // ROW 8 — Called from ProductRequestTrigger (after update)
    // Fires when fax__Product_Request__c Status changes to 'Received'
    // Gets all child items to build parts summary
    // ════════════════════════════════════════════════════════════════════════
    public static void sendSMSPartRequestReceived(
        List<fax__Product_Request__c> newList,
        Map<Id, fax__Product_Request__c> oldMap
    ) {
        // Find PRs that just changed to Received
        Set<Id> receivedIds = new Set<Id>();
        for (fax__Product_Request__c pr : newList) {
            fax__Product_Request__c oldPr = oldMap != null ? oldMap.get(pr.Id) : null;
            Boolean justReceived = oldPr != null &&
                pr.fax__Status__c == 'Received' &&
                oldPr.fax__Status__c != 'Received';
            if (justReceived && pr.fax__Job__c != null)
                receivedIds.add(pr.Id);
        }
        if (receivedIds.isEmpty()) return;

        // Query PRs with Job + Engineer
        Map<Id, fax__Product_Request__c> prMap = new Map<Id, fax__Product_Request__c>([
            SELECT Id, Name,
                   fax__Job__c,
                   fax__Job__r.Name,
                   fax__Job__r.Service_Engineer__c
            FROM   fax__Product_Request__c
            WHERE  Id IN :receivedIds
            AND    fax__Job__c != null
        ]);

        // Collect Engineer IDs
        Set<Id> engIds = new Set<Id>();
        for (fax__Product_Request__c pr : prMap.values()) {
            if (pr.fax__Job__r.Service_Engineer__c != null)
                engIds.add(pr.fax__Job__r.Service_Engineer__c);
        }
        if (engIds.isEmpty()) return;

        // Query Engineers
        Map<Id, fax__Service_Engineer__c> engMap = new Map<Id, fax__Service_Engineer__c>([
            SELECT Id, Name, fax__Phone__c
            FROM   fax__Service_Engineer__c
            WHERE  Id IN :engIds
        ]);

        // Query child items for all received PRs
        Map<Id, List<fax__Product_Request_Item__c>> itemsByPrId =
            new Map<Id, List<fax__Product_Request_Item__c>>();

        for (fax__Product_Request_Item__c item : [
            SELECT Id, fax__Product_Name__c, fax__Qty__c, fax__Product_Request__c
            FROM   fax__Product_Request_Item__c
            WHERE  fax__Product_Request__c IN :receivedIds
            ORDER BY CreatedDate ASC
        ]) {
            if (!itemsByPrId.containsKey(item.fax__Product_Request__c))
                itemsByPrId.put(item.fax__Product_Request__c,
                    new List<fax__Product_Request_Item__c>());
            itemsByPrId.get(item.fax__Product_Request__c).add(item);
        }

        // Send SMS
        for (Id prId : receivedIds) {
            fax__Product_Request__c pr = prMap.get(prId);
            if (pr == null) continue;

            fax__Service_Engineer__c eng =
                engMap.get(pr.fax__Job__r.Service_Engineer__c);
            if (eng == null || String.isBlank(eng.fax__Phone__c)) continue;

            String jobNo       = nvl(pr.fax__Job__r.Name);
            String partSummary = buildPartSummary(itemsByPrId.get(prId));

            String msg = SMSTemplateService.build(
                SMSTemplateService.PART_REQUEST_APPROVED,
                new Map<String, String>{
                    'EngineerName' => nvl(eng.Name),
                    'JobNo'        => jobNo,
                    'PartName'     => partSummary
                }
            );
            if (String.isNotBlank(msg)) {
                RingCentralSMSService.sendSMS(eng.fax__Phone__c, msg);
                System.debug('[ProductRequestTriggerHandler] ✅ Row 8 sent | '
                    + 'Parts: ' + partSummary
                    + ' | Engineer: ' + eng.Name);
            }
        }
    }

    // Build "PartName x Qty, PartName x Qty" summary from child items
    private static String buildPartSummary(List<fax__Product_Request_Item__c> items) {
        if (items == null || items.isEmpty()) return 'N/A';
        List<String> parts = new List<String>();
        for (fax__Product_Request_Item__c item : items) {
            String name = String.isNotBlank(item.fax__Product_Name__c)
                ? item.fax__Product_Name__c : 'Part';
            String qty  = item.fax__Qty__c != null
                ? String.valueOf(item.fax__Qty__c.intValue()) : '1';
            parts.add(name + ' x' + qty);
        }
        return String.join(parts, ', ');
    }

    private static String nvl(String val) {
        return String.isNotBlank(val) ? val : '';
    }
}