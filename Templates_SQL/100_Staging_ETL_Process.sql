USE [100_Staging_Area]

-- Parameters
DECLARE @targetDatabase				VARCHAR(100) = '[100_Staging_Area]';
DECLARE @targetSchema				VARCHAR(100) = '[dbo]';
DECLARE @sourceDatabase				VARCHAR(100) = '[000_Source]';
DECLARE @sourceSchema				VARCHAR(100) = '[dbo]';
DECLARE @psaDatabase				VARCHAR(100) = '[150_Persistent_Staging_Area]';
DECLARE @psaSchema					VARCHAR(100) = '[dbo]';
DECLARE @loadDateTimeAttribute		VARCHAR(100) = '[LOAD_DATETIME]';
DECLARE @eventDateTimeAttribute		VARCHAR(100) = '[EVENT_DATETIME]';
DECLARE @etlProcessIdAttribute		VARCHAR(100) = '[ETL_INSERT_RUN_ID]';
DECLARE @recordSourceAttribute		VARCHAR(100) = '[RECORD_SOURCE]';
DECLARE @checksumAttribute			VARCHAR(100) = '[HASH_FULL_RECORD]';
DECLARE @cdcAttribute				VARCHAR(100) = '[CDC_OPERATION]';
DECLARE @stgPrefix					VARCHAR(100) = 'STG_';
DECLARE @psaPrefix					VARCHAR(100) = 'PSA_';
-- Variables input / metadata (from the metadata database)
DECLARE @targetTable				VARCHAR(100);	-- The Staging Area (target) table name
DECLARE @sourceTable				VARCHAR(100);	-- The source table name
DECLARE @naturalKeyAttributeName	VARCHAR(100);	-- A local variable for use in the natural key cursor
DECLARE @attributeName				VARCHAR(MAX);	-- A local variable for use in the attribute cursor
-- Variabels local / helper
DECLARE @pattern					VARCHAR(MAX);	-- The complete selection / generated output 
DECLARE @recordSourceName			VARCHAR(100);	-- The drived record source value (derived from the target table name)
DECLARE @naturalKeySelectPart		VARCHAR(100);	-- The listing of all in-scope key parts of the natural key for the SELECT statement (inserted as a block)
DECLARE @naturalKeyJoinPart			VARCHAR(MAX);	-- The constructed JOIN condition between the STG and PSA based on the Natural Key (inserted as a block)
DECLARE @attributeSelectPart		VARCHAR(MAX);	-- The listing of all in-scope attributes for the SELECT statement (inserted as a block)
DECLARE @attributeChecksumPart		VARCHAR(MAX);	-- The constructed hashbytes for all attributes (inserted as a block)
DECLARE @attributeChangeEvalPart	VARCHAR(MAX);	-- The constructed evaluation for changes, for each attribute (inserted as a block)
DECLARE @naturalKeyCursorSelection	NVARCHAR(MAX);	-- Dynamic SQL to drive the cursor, to make full use of the parameters (no hard-coding)
DECLARE @naturalKey_cursor			CURSOR;			-- The cursor to cycle through natural key (source Primary Key) columns, required as variable because of dynamic SQL input


-- The cursor is designed to 'pull' into Staging, as opposed to 'push' from the source. This provides better control of which metadata gets used.
-- This cursor is the main / 'outer' cursor which cycles through the tables and creates the source-to-staging pattern
DECLARE stg_cursor CURSOR FOR   
  SELECT [TABLE_NAME]
  FROM INFORMATION_SCHEMA.TABLES 
  WHERE [TABLE_TYPE]='BASE TABLE' 
  AND TABLE_NAME NOT LIKE '%_USERMANAGED_%' -- User Managed tables do not have a source as such

OPEN stg_cursor  

FETCH NEXT FROM stg_cursor   
INTO @targetTable

WHILE @@FETCH_STATUS = 0  
BEGIN

	--Clear out local variables where required for each new iteration
	SET @attributeSelectPart='';
	SET @attributeChecksumPart = '';
	SET @naturalKeySelectPart='';
	SET @attributeChangeEvalPart='';
	SET @naturalKeyJoinPart='';
	SET @naturalKeyCursorSelection='';

	--Capture the local variables covering the source and record source  
	SET @sourceTable = REPLACE(@targetTable,@stgPrefix,''); --Remove the Staging Prefix
	SET @recordSourceName = SUBSTRING(@sourceTable,1,CHARINDEX('_',@sourceTable,1)-1); -- Extract the value of the record source
	SET @sourceTable = REPLACE(@sourceTable,@recordSourceName+'_',''); --Finally remove the record source as well to store the source table name


	--1st inner Cursor: retrieve the natural keys, this is needed because some natural keys (= source Primary Keys) can be composite
	--This is a dynamic SQL based cursor due to the requirement to have parameters as source databases
	SET @naturalKeyCursorSelection = @naturalKeyCursorSelection+'SET @cursor = CURSOR FORWARD_ONLY STATIC FOR'+CHAR(13);
	SET @naturalKeyCursorSelection = @naturalKeyCursorSelection+'	SELECT sc.name '+CHAR(13);
	SET @naturalKeyCursorSelection = @naturalKeyCursorSelection+'	  FROM '+@sourceDatabase+'.sys.objects as so '+CHAR(13);
	SET @naturalKeyCursorSelection = @naturalKeyCursorSelection+'	  INNER JOIN '+@sourceDatabase+'.sys.indexes as si on so.object_id = si.object_id and si.is_primary_key = 1 '+CHAR(13);
	SET @naturalKeyCursorSelection = @naturalKeyCursorSelection+'	  INNER JOIN '+@sourceDatabase+'.sys.index_columns as ic  on si.object_id = ic.object_id and si.index_id = ic.index_id '+CHAR(13);
	SET @naturalKeyCursorSelection = @naturalKeyCursorSelection+'	  INNER JOIN '+@sourceDatabase+'.sys.columns as sc on so.object_id = sc.object_id and ic.column_id = sc.column_id '+CHAR(13);
	SET @naturalKeyCursorSelection = @naturalKeyCursorSelection+'	  WHERE so.name='''+@sourceTable+''''+CHAR(13);
	SET @naturalKeyCursorSelection = @naturalKeyCursorSelection+'	  ORDER BY index_column_id'+CHAR(13);
	SET @naturalKeyCursorSelection = @naturalKeyCursorSelection+'OPEN @cursor'+CHAR(13);

	EXEC sys.sp_executesql    @naturalKeyCursorSelection,N'@cursor cursor output',@naturalKey_cursor output
  
	FETCH NEXT FROM @naturalKey_cursor INTO @naturalKeyAttributeName

	WHILE @@FETCH_STATUS = 0  
	BEGIN  	
	    
		-- Create the block of key attributes for use in various ORDER BY and SELECT statements
		SET @naturalKeySelectPart = @naturalKeySelectPart+'    ['+@naturalKeyAttributeName+'],'+CHAR(13);

		-- Create the JOIN condition to be added to the pattern to achieve the Full Outer Join
		SET @naturalKeyJoinPart = @naturalKeyJoinPart+'  PSA_CTE.['+@naturalKeyAttributeName+'] = STG_CTE.['+@naturalKeyAttributeName+'] AND'+CHAR(13);

		FETCH NEXT FROM @naturalKey_cursor   
		INTO  @naturalKeyAttributeName
	END  

	CLOSE @naturalKey_cursor;  
	DEALLOCATE @naturalKey_cursor;  
	--End of natural key cursor


	--2nd inner Cursor: retrieve the attributes (from the target table)
	DECLARE attribute_cursor CURSOR FOR
		SELECT COLUMN_NAME
		FROM INFORMATION_SCHEMA.COLUMNS
		WHERE TABLE_NAME=''+@targetTable+''
		AND COLUMN_NAME NOT IN ('ETL_INSERT_RUN_ID','LOAD_DATETIME','EVENT_DATETIME','RECORD_SOURCE','SOURCE_ROW_ID','CDC_OPERATION','HASH_FULL_RECORD')
		ORDER BY ORDINAL_POSITION

	OPEN attribute_cursor
	  
	FETCH NEXT FROM attribute_cursor INTO @attributeName

	WHILE @@FETCH_STATUS = 0  
	BEGIN  
	    -- Construct the block of attributes for use in SELECT statements
		SET @attributeSelectPart = @attributeSelectPart+'  ['+@attributeName+'],'+CHAR(13);

		-- Construct the checksum across all attributes
		SET @attributeChecksumPart = @attributeChecksumPart+'    ISNULL(RTRIM(CONVERT(NVARCHAR(100),['+ @attributeName +'])),''NA'')+''|'' +'+CHAR(13);

		-- Construct the evaluation for change
		SET @attributeChangeEvalPart = @attributeChangeEvalPart+'  CASE WHEN STG_CTE.['+@naturalKeyAttributeName+'] IS NULL THEN PSA_CTE.['+ @attributeName +'] ELSE STG_CTE.['+ @attributeName +'] END AS ['+ @attributeName +'],'+CHAR(13);

		FETCH NEXT FROM attribute_cursor INTO @attributeName
	END  

	CLOSE attribute_cursor;  
	DEALLOCATE attribute_cursor;  
	--End of attribute cursor

	-- Remove trailing commas and delimiters
	SET @attributeChecksumPart = LEFT(@attributeChecksumPart,DATALENGTH(@attributeChecksumPart)-2)+CHAR(13)
	SET @naturalKeySelectPart = LEFT(@naturalKeySelectPart,DATALENGTH(@naturalKeySelectPart)-2)+CHAR(13)
	SET @naturalKeyJoinPart = LEFT(@naturalKeyJoinPart,DATALENGTH(@naturalKeyJoinPart)-5)+CHAR(13)

	-- Source to Staging Full Outer Join Pattern
 	SET @pattern = '-- Working on mapping to ' +  @targetTable + ' from source table ' + @sourceTable+CHAR(13)+CHAR(13);
	SET @pattern = @pattern+'USE '+@targetDatabase+';'+CHAR(13)+CHAR(13);
	SET @pattern = @pattern+'DELETE FROM '+@targetDatabase+'.'+@targetSchema+'.['+@targetTable+'];'+CHAR(13)+CHAR(13);
		-- Start of source selection statement
	SET @pattern = @pattern+'WITH STG_CTE AS '+CHAR(13)+'('+CHAR(13);
	SET @pattern = @pattern+'SELECT'+CHAR(13);
	SET @pattern = @pattern+@attributeSelectPart
	SET @pattern = @pattern+'  HASHBYTES(''MD5'','+CHAR(13);
	SET @pattern = @pattern+@attributeChecksumPart;
	SET @pattern = @pattern+'  ) AS '+@checksumAttribute+CHAR(13);
	SET @pattern = @pattern+'FROM '+@sourceDatabase+'.'+@sourceSchema+'.['+@sourceTable+']'+CHAR(13);
		-- End of source selection statement
		-- Start of PSA selection statement
	SET @pattern = @pattern+'), PSA_CTE AS'+CHAR(13);
	SET @pattern = @pattern+'('+CHAR(13);
	SET @pattern = @pattern+'SELECT * FROM ('+CHAR(13);
	SET @pattern = @pattern+'  SELECT'+CHAR(13);
	SET @pattern = @pattern+@attributeSelectPart;
	SET @pattern = @pattern+'  '+@checksumAttribute+','+CHAR(13);
	SET @pattern = @pattern+'  '+'ROW_NUMBER() OVER (PARTITION  BY '+CHAR(13);
	SET @pattern = @pattern+@naturalKeySelectPart;
	SET @pattern = @pattern+'  '+'ORDER BY'+CHAR(13);
	SET @pattern = @pattern+@naturalKeySelectPart+'    ,'+@loadDateTimeAttribute+' DESC'+CHAR(13);
	SET @pattern = @pattern+'  '+') AS [ROW_NR]'+CHAR(13);
	SET @pattern = @pattern+'  FROM '+@psaDatabase+'.'+@psaSchema+'.['+@psaPrefix+@recordSourceName+'_'+@sourceTable+']'+CHAR(13);
	SET @pattern = @pattern+'  WHERE '+@cdcAttribute+'!=''Delete'') sub'+CHAR(13);
	SET @pattern = @pattern+'WHERE ROW_NR=1'+CHAR(13);
	SET @pattern = @pattern+')'+CHAR(13);
		-- End of PSA selection statement
		-- Start of INSERT INTO statement
	SET @pattern = @pattern+'INSERT INTO '+@targetDatabase+'.'+@targetSchema+'.['+@targetTable+']'+CHAR(13);
	SET @pattern = @pattern+'('+CHAR(13)+@attributeSelectPart;
	SET @pattern = @pattern+'  '+@checksumAttribute+','+CHAR(13);
	SET @pattern = @pattern+'  '+@etlProcessIdAttribute+','+CHAR(13);
	SET @pattern = @pattern+'  '+@recordSourceAttribute+','+CHAR(13);
	SET @pattern = @pattern+'  '+@cdcAttribute+','+CHAR(13);
	SET @pattern = @pattern+'  '+@eventDateTimeAttribute+CHAR(13);
	SET @pattern = @pattern+')'+CHAR(13); -- Add the attribtes to insert into the target table
	   -- End of INSERT INTO statement
		-- Start of selection and join statement / final result
	SET @pattern = @pattern+'SELECT'+CHAR(13);
	SET @pattern = @pattern+@attributeChangeEvalPart; --The attributes
	SET @pattern = @pattern+'  CASE WHEN STG_CTE.['+@naturalKeyAttributeName+'] IS NULL THEN PSA_CTE.'+@checksumAttribute+' ELSE STG_CTE.'+@checksumAttribute+' END AS '+@checksumAttribute+', '+CHAR(13); -- The checksum
	SET @pattern = @pattern+'  -1 AS'+@etlProcessIdAttribute+','+CHAR(13); -- ETL Process ID
	SET @pattern = @pattern+'  '''+@recordSourceName+''' AS '+@recordSourceAttribute+','+CHAR(13); -- Record Source
	SET @pattern = @pattern+'  CASE'+CHAR(13);
	SET @pattern = @pattern+'    WHEN STG_CTE.['+@naturalKeyAttributeName+'] IS NULL THEN ''Delete'''+CHAR(13);
	SET @pattern = @pattern+'    WHEN PSA_CTE.['+@naturalKeyAttributeName+'] IS NULL THEN ''Insert'''+CHAR(13);
	SET @pattern = @pattern+'    WHEN STG_CTE.['+@naturalKeyAttributeName+'] IS NOT NULL AND PSA_CTE.['+@naturalKeyAttributeName+'] IS NOT NULL AND STG_CTE.'+@checksumAttribute+' != PSA_CTE.'+@checksumAttribute+' THEN ''Change'''+CHAR(13);
	SET @pattern = @pattern+'    ELSE ''No Change'''+CHAR(13);
	SET @pattern = @pattern+'  END AS '+@cdcAttribute+','+CHAR(13); -- CDC attribute
	SET @pattern = @pattern+'  SYSDATETIME() AS '+@eventDateTimeAttribute+CHAR(13); -- Event Date/Time
	SET @pattern = @pattern+'FROM STG_CTE'+CHAR(13);
	SET @pattern = @pattern+'FULL OUTER JOIN PSA_CTE ON '+CHAR(13);
	SET @pattern = @pattern+@naturalKeyJoinPart;
	SET @pattern = @pattern+'WHERE '+CHAR(13);
	SET @pattern = @pattern+'  CASE'+CHAR(13);
	SET @pattern = @pattern+'    WHEN STG_CTE.['+@naturalKeyAttributeName+'] IS NULL THEN ''Delete'''+CHAR(13);
	SET @pattern = @pattern+'    WHEN PSA_CTE.['+@naturalKeyAttributeName+'] IS NULL THEN ''Insert'''+CHAR(13);
	SET @pattern = @pattern+'    WHEN STG_CTE.['+@naturalKeyAttributeName+'] IS NOT NULL AND PSA_CTE.['+@naturalKeyAttributeName+'] IS NOT NULL AND STG_CTE.'+@checksumAttribute+' != PSA_CTE.'+@checksumAttribute+' THEN ''Change'''+CHAR(13);
	SET @pattern = @pattern+'    ELSE ''No Change'''+CHAR(13);
	SET @pattern = @pattern+'  END != ''No Change'''+CHAR(13)+CHAR(13);
  
	-- Spool the pattern to the console
   	PRINT @pattern+CHAR(13);     
		 
    FETCH NEXT FROM stg_cursor   
	INTO @targetTable
END  
 
CLOSE stg_cursor;  
DEALLOCATE stg_cursor;  