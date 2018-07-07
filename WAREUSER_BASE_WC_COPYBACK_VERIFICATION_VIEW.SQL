--*********************************************************************************************
--** Login into HANA as "WAREUSER_ADMIN" to run the following:
--**
--*********************************************************************************************
--** Set Schema
SET SCHEMA WAREUSER_BASE;

DROP VIEW WAREUSER_BASE.WC_COPYBACK_VERIFICATION;

CREATE VIEW WAREUSER_BASE.WC_COPYBACK_VERIFICATION AS
SELECT 
        --*********************************************************************************************
        --** Name: WAREUSER_BASE.WC_COPYBACK_VERIFICATION
        --** Desc: This views provides information from HANA and Oracle for the tables that are copied 
        --**       back to the WAREUSER_HANA schema in Oracle using the DataServices job - JOB_REPL_HANA_PERSIST.
        --**
        --**       - Table Name  - List of Table parameters for the Copy Back process
        --**       - Active Flag - Is the table copied back to Oracle from HANA
        --**       - Persisted Object - Is the object persisted in HANA
        --**       - Persistence Frequency - if the object is persisted, what is the associated persistence frequency
        --**       - DS Copy Back Frequency - What is the DataServices Workflow persistence frequency
        --**       - Create Date - Date/Time object was created in Oracle (it uses the analyze date but it should be within 15minutes of the create date)
        --**       - Latest PK Violation - Latest Primary Key violation from the BATCH_JOB_KEY_VIOLATION_RESULTS table
        --**       - Table Depends On Persisted Objects - The object is persisted or depends on a persisted object
        --**       - Status - is there a scenario that needs further attention
        --**
        --**
        --** Parm: None
        --**
        --*********************************************************************************************
        --** Change History
        --*********************************************************************************************
        --** TICKET #   Date          Kerberos ID     Description    
        --** --------   ----------    ------------    ----------------------------------------
        --** WH-1060    05/11/2018    keithjoh        Architecture: Strategy for Pushing Objects to WC
        --** 
        --*********************************************************************************************
        -- Show us all of the tables that are being pushed to WAREUSER_HANA - see comments in joins for 
        -- information on what we're displaying
        REPLACE(BP.PARAMETER_CODE,'_FULL_LOAD','') AS TABLE_NAME
        , BP.PARAMETER_VALUE AS ACTIVE_FLAG
        , MAP(PF.TARGET_TABLE,NULL,'N','Y') AS PERSISTED_OBJECT
        , PF.PERSISTENCE_FREQUENCY
        , DS.PERSISTENCE_FREQUENCY AS DS_COPY_BACK_FREQUENCY
        , WH.CREATE_DATE
        , CASE WHEN PF.TARGET_TABLE IS NULL AND DON.DEPENDENT_OBJECT_NAME IS NULL THEN 'N'
               ELSE 'Y' END AS TABLE_DEPENDS_ON_PERSISTED_OBJECT
        , PK.MAX_WAREHOUSE_INSERT_TIMESTAMP AS LATEST_PK_VIOLATION
        , CASE WHEN BP.PARAMETER_VALUE='Y' AND WH.CREATE_DATE IS NULL THEN 'NEEDS ATTENTION - Table missing or no WAREHOUSE_LOAD_DATE column in table'
               WHEN PF.PERSISTENCE_FREQUENCY <> DS.PERSISTENCE_FREQUENCY THEN 'NEEDS ATTENTION'
               WHEN PF.TARGET_TABLE IS NULL AND DON.DEPENDENT_OBJECT_NAME IS NULL AND DS.PERSISTENCE_FREQUENCY<>'NEAR_REAL_TIME_CPYBCKONLY' THEN 'MOVE TO DS - NEAR_REAL_TIME_CPYBCKONLY'
               ELSE '' END AS STATUS
FROM WAREUSER_BASE.BATCH_JOB_PARAMETERS BP
-- Join to the list of objects that are being persisted to get the persistence_frequency
LEFT JOIN (SELECT TARGET_TABLE, PERSISTENCE_FREQUENCY
           FROM WAREUSER_BASE.PERSISTED_TABLES_REFRESH_SCHEDULE
           WHERE ACTIVE_FLAG = 'Y'
             AND PERSISTENCE_FREQUENCY IN ('NEAR_REAL_TIME','NEAR_REAL_TIME_2','NIGHTLY_STATIC','NEAR_REAL_TIME_CPYBCKONLY') 
           ORDER BY 1, 2) PF ON PF.TARGET_TABLE = REPLACE(BP.PARAMETER_CODE,'_FULL_LOAD','')
-- Join to the list of objects in Oracle to get the last date the object was pushed (CREATE_DATE, above)
LEFT JOIN (SELECT TABLE_NAME, LAST_ANALYZED AS CREATE_DATE
           FROM WAREUSER_BASE.SDA_WAREUSER_CLASSIC_OBJECTS
           WHERE OWNER = 'WAREUSER_HANA'
             AND COLUMN_NAME = 'WAREHOUSE_LOAD_DATE'
             AND LEFT(TABLE_NAME,2) NOT IN ('LD','BK')
             AND TABLE_NAME NOT LIKE 'BIN%') WH ON WH.TABLE_NAME = REPLACE(BP.PARAMETER_CODE,'_FULL_LOAD','')  
 -- Join to the Data services repository to get details on past pushes of these objects
LEFT JOIN (SELECT REPLACE(REPLACE(DESCEN_OBJ,'WF_HANA_DWC_',''),'_WH',', WH') AS TABLE_NAME
                  , REPLACE(REPLACE(PARENT_OBJ,'WF_HP_WC_CopyBack_',''),'_Detail','') AS PERSISTENCE_FREQUENCY
           ------------------------------------------------------------------------
           -- Uncomment the respective DS Repository Schema based on environment
           ------------------------------------------------------------------------
           -- DMD - Development Table
           ------------------------------------------------------------------------
           FROM DS_LR_07_USER.ALVW_PARENT_CHILD
           ------------------------------------------------------------------------
           -- DMQ - Test Table
           ------------------------------------------------------------------------
           --FROM DIQ_DS_LR_01.ALVW_PARENT_CHILD
           ------------------------------------------------------------------------
           -- DMP - Production Table
           ------------------------------------------------------------------------
           --FROM DS1_DS_LR_01.ALVW_PARENT_CHILD
          ------------------------------------------------------------------------       
           WHERE PARENT_OBJ IN ('WF_HP_WC_CopyBack_NEAR_REAL_TIME_Detail','WF_HP_WC_CopyBack_NEAR_REAL_TIME_CPYBCKONLY_Detail','WF_HP_WC_CopyBack_NEAR_REAL_TIME_2_Detail','WF_HP_WC_CopyBack_NIGHTLY_STATIC_Detail')
           UNION
           -- WHHR_APPT_TX_DETAIL and WHHR_APPOINTMENT_DETAIL are in the same data flow, so we have to add them manually
           SELECT 'WHHR_APPT_TX_DETAIL', 'NIGHTLY_STATIC' FROM DUMMY
           UNION
           SELECT 'WHHR_APPOINTMENT_DETAIL', 'NIGHTLY_STATIC' FROM DUMMY
          ORDER BY 1,2) DS ON DS.TABLE_NAME = REPLACE(BP.PARAMETER_CODE,'_FULL_LOAD','')
-- Join to HANA object dependences to get HANA object dependencies
LEFT JOIN (SELECT DISTINCT OD.DEPENDENT_OBJECT_NAME
           FROM OBJECT_DEPENDENCIES OD JOIN WAREUSER_BASE.PERSISTED_TABLES_REFRESH_SCHEDULE RS ON OD.BASE_SCHEMA_NAME = RS.TARGET_SCHEMA AND OD.BASE_OBJECT_NAME = RS.TARGET_TABLE
           WHERE RS.ACTIVE_FLAG = 'Y') DON ON DON.DEPENDENT_OBJECT_NAME = REPLACE(BP.PARAMETER_CODE,'_FULL_LOAD','')
-- Join to get PK violation details 
LEFT JOIN (SELECT SUBSTR_AFTER(QUALIFIED_OBJECT_NAME,'.') AS TABLE_NAME
                  , MAX(WAREHOUSE_INSERT_TIMESTAMP) AS MAX_WAREHOUSE_INSERT_TIMESTAMP
           FROM WAREUSER_BASE.BATCH_JOB_KEY_VIOLATION_RESULTS
           GROUP BY SUBSTR_AFTER(QUALIFIED_OBJECT_NAME,'.')) PK ON PK.TABLE_NAME = REPLACE(BP.PARAMETER_CODE,'_FULL_LOAD','')
WHERE BP.JOB_CODE = 'JOB_REPL_HANA_PERSIST'
  AND BP.PARAMETER_CODE LIKE '%_FULL_LOAD'
ORDER BY 1,4,5
;
