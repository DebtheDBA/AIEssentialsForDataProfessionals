IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Customer' AND type = 'U')
CREATE TABLE [dbo].[Customer](
	[CustomerID] [int] IDENTITY(1,1) NOT NULL
		CONSTRAINT PK_Customer PRIMARY KEY CLUSTERED,
	[FirstName] [varchar](100) NULL,
	[LastName] [varchar](100) NULL,
	[Address] [varchar](50) NULL,
	[City] [varchar](50) NULL,
	[State] [char](2) NULL,
	[ZipCode] [char](5) NULL,
	[Email] [varchar](100) NULL,
	[PhoneNumber] [char](15) NULL,
	[FirstVisit] [date] NULL,
	[RepeatCustomer] [bit] NULL
 )
GO
