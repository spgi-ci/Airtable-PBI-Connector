// AirTable Connector for PowerBI
// Only supports Personal Access Token authentication
// The token MUST have schema.bases:read and data.records:read permissions

// MIT License

// Copyright (c) 2023 S&P Global

// All rights reserved.

// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

[Version = "1.0.0"]
section AirTableConnector;

// Adapted from code posted by AirTable support 
// https://support.airtable.com/docs/visualizing-airtable-records-in-microsoft-power-bi-power-query
// Calls the API for a relative path and paginates through using the offset parameter
// objectName is set as the column name for the returned object
// Returns a table of the values
CallAirTableAPI = (relativePath as text, objectName as text) as table =>
    let
        PERSONAL_ACCESS_TOKEN = Extension.CurrentCredential()[Key],
        Pagination = List.Skip(
            List.Generate(
                () => [Page_Key = "init", Counter = 0],
                // Start Value
                each [Page_Key] <> null,
                // Condition under which the next execution will happen
                each
                    [
                        Page_Key = try if [Counter] < 1 then "" else[WebCall][Value][offset] otherwise null,
                        // determine the LastKey for the next execution
                        WebCall = try
                            if [Counter] < 1 then
                                Json.Document(
                                    Web.Contents(
                                        "https://api.airtable.com",
                                        [
                                            RelativePath = relativePath,
                                            Headers = [Authorization = "Bearer " & PERSONAL_ACCESS_TOKEN]
                                        ]
                                    )
                                )
                            else
                                Json.Document(
                                    Web.Contents(
                                        "https://api.airtable.com",
                                        [
                                            RelativePath = relativePath & "?offset=" &[WebCall][Value][offset],
                                            Headers = [Authorization = "Bearer " & PERSONAL_ACCESS_TOKEN]
                                        ]
                                    )
                                ),
                        // retrieve results per call
                        Counter = [Counter] + 1
                        // internal counter
                    ],
                each [WebCall]
            ),
            1
        ),
        tabular = Table.FromList(Pagination, Splitter.SplitByNothing(), null, null, ExtraValues.Error),
        expandColumn = Table.ExpandRecordColumn(
            tabular, "Column1", {"HasError", "Value"}, {"HasError", objectName}
        ),
        expandColumnValue = Table.ExpandRecordColumn(
            expandColumn, objectName, {objectName}, {objectName}
        ),
        expandTablesList = Table.ExpandListColumn(expandColumnValue, objectName)
    in
        expandTablesList;

// Given a base ID and a tableName get the contents of the table as a table
GetTable = (baseID as text, tableName as text) as table =>
    let
        asTable = CallAirTableAPI("v0/" & baseID & "/" & tableName, "records"),
        expandNestedRecords = Table.ExpandRecordColumn(
            asTable,
            "records",
            {"id", "fields", "createdTime"},
            {"records.id", "records.fields", "records.createdTime"}
        ),
        renameColumns = Table.RenameColumns(
            expandNestedRecords,
            {
                {"records.id", "_airtableRecordId"},
                {"records.createdTime", "_airtableRecordCreatedAt"},
                {"records.fields", "_airtableRecordFields"}
            }
        ),
        reorderColumns = Table.ReorderColumns(
            renameColumns, {"_airtableRecordId", "_airtableRecordCreatedAt", "_airtableRecordFields"}
        ),
        setCreateDateType = Table.TransformColumnTypes(reorderColumns,{{"_airtableRecordCreatedAt", type datetimezone}}),
        finalTable = Table.ExpandRecordColumn(
            setCreateDateType,
            "_airtableRecordFields",
            Record.FieldNames(reorderColumns{0}[_airtableRecordFields]),
            Record.FieldNames(reorderColumns{0}[_airtableRecordFields])
        )
    in
        finalTable;

// Given a base ID get all the tables in the base (used for navigation)
GetTables = (baseID as text) as table =>
    let
        asTable = CallAirTableAPI("v0/meta/bases/" & baseID & "/tables","tables"),
        expandTablesRecord = Table.ExpandRecordColumn(
            asTable, "tables", {"id", "name"}, {"Key", "Name"}
        ),
        removeErrorColumn = Table.RemoveColumns(expandTablesRecord, {"HasError"}),
        addKindMeta = Table.AddColumn(removeErrorColumn, "ItemKind", each "Table", type text),
        addNameMeta = Table.AddColumn(addKindMeta, "ItemName", each "Table", type text),
        addisLeafMeta = Table.AddColumn(addNameMeta, "IsLeaf", each true, type logical),
        addData = Table.AddColumn(addisLeafMeta,"Data", each GetTable(baseID,[Key]), type table),
        finalTable = Table.ToNavigationTable(addData,{"Key"},"Name","Data","ItemKind","ItemName","IsLeaf")
    in
        finalTable;

// Get all AirTable bases that the personal access token has access to
GetBases = () as table =>
    let
        asTable = CallAirTableAPI("v0/meta/bases","bases"),
        expandListtoBases = Table.ExpandRecordColumn(asTable, "bases", {"id", "name", "permissionLevel"}, {"Key", "Name", "permissionLevel"}),
        removeErrorColumn = Table.RemoveColumns(expandListtoBases, {"HasError"}),
        withTables = Table.AddColumn(removeErrorColumn, "Data", each GetTables([Key]), type table),
        dropColumn = Table.RemoveColumns(withTables,{"permissionLevel"}),
        addKindMeta = Table.AddColumn(dropColumn, "ItemKind", each "Database", type text),
        addNameMeta = Table.AddColumn(addKindMeta, "ItemName", each "Database", type text),
        finalTable = Table.AddColumn(addNameMeta, "IsLeaf", each false, type logical)
    in
        finalTable;

[DataSource.Kind = "AirTableConnector", Publish = "AirTableConnector.Publish"]
shared AirTableConnector.Contents = () =>
    let
        bases = GetBases(),
        navTable = Table.ToNavigationTable(bases,{"Key"},"Name","Data","ItemKind","ItemName","IsLeaf")
    in
        navTable;

// Data Source Kind description
AirTableConnector = [
    // if we can get the bases available using the PAT then we have a connection
    TestConnection = (dataSourcePath) => {"AirTableConnector.Contents"},    
    Authentication = [
        Key = [KeyLabel = Extension.LoadString("KeyLabel"),
        Label = Extension.LoadString("PATLabel")]
    ],
    Label = Extension.LoadString("DataSourceLabel")
];

// Data Source UI publishing description
AirTableConnector.Publish = [
    Beta = true,
    Category = "Other",
    ButtonText = {Extension.LoadString("ButtonTitle"), Extension.LoadString("ButtonHelp")},
    LearnMoreUrl = "https://support.airtable.com/docs/visualizing-airtable-records-in-microsoft-power-bi-power-query",
    SourceImage = AirTableConnector.Icons,
    SourceTypeImage = AirTableConnector.Icons
];

AirTableConnector.Icons = [
    Icon16 = {
        Extension.Contents("AirTableConnector16.png"),
        Extension.Contents("AirTableConnector20.png"),
        Extension.Contents("AirTableConnector24.png"),
        Extension.Contents("AirTableConnector32.png")
    },
    Icon32 = {
        Extension.Contents("AirTableConnector32.png"),
        Extension.Contents("AirTableConnector40.png"),
        Extension.Contents("AirTableConnector48.png"),
        Extension.Contents("AirTableConnector64.png")
    }
];

// Common library code - convert a table to a navigation table recognized by PBI
Table.ToNavigationTable = (
    table as table,
    keyColumns as list,
    nameColumn as text,
    dataColumn as text,
    itemKindColumn as text,
    itemNameColumn as text,
    isLeafColumn as text
) as table =>
    let
        tableType = Value.Type(table),
        newTableType = Type.AddTableKey(tableType, keyColumns, true) meta [
            NavigationTable.NameColumn = nameColumn,
            NavigationTable.DataColumn = dataColumn,
            NavigationTable.ItemKindColumn = itemKindColumn,
            Preview.DelayColumn = itemNameColumn,
            NavigationTable.IsLeafColumn = isLeafColumn
        ],
        navigationTable = Value.ReplaceType(table, newTableType)
    in
        navigationTable;