{ ****************************************************************************** }
{ * CrossSocket support                                                        * }
{ * written by QQ 600585@qq.com                                                * }
{ * https://github.com/PassByYou888/CoreCipher                                 * }
(* https://github.com/PassByYou888/ZServer4D *)
{ ****************************************************************************** }
(*
  update history
*)
unit CommunicationFramework_Server_CrossSocket;

{$I ..\zDefine.inc}

interface

uses SysUtils, Classes,
  Net.CrossSocket, Net.SocketAPI, Net.CrossSocket.Base, Net.CrossServer,
  PascalStrings,
  CommunicationFramework, CoreClasses, UnicodeMixedLib, MemoryStream64,
  DataFrameEngine;

type
  TContextIntfForServer = class(TPeerClient)
  public
    LastActiveTime: TTimeTickValue;
    Sending       : Boolean;
    SendBuffQueue : TCoreClassListForObj;
    CurrentBuff   : TMemoryStream64;

    procedure CreateAfter; override;
    destructor Destroy; override;

    function Context: TCrossConnection;
    function Connected: Boolean; override;
    procedure Disconnect; override;
    procedure SendBuffResult(AConnection: ICrossConnection; ASuccess: Boolean);
    procedure SendByteBuffer(const buff: PByte; const Size: NativeInt); override;
    procedure WriteBufferOpen; override;
    procedure WriteBufferFlush; override;
    procedure WriteBufferClose; override;
    function GetPeerIP: SystemString; override;
    function WriteBufferEmpty: Boolean; override;
  end;

  TDriverEngine = TCrossSocket;

  TCommunicationFramework_Server_CrossSocket = class(TCommunicationFrameworkServer)
  private
    FDriver        : TDriverEngine;
    FStartedService: Boolean;
    FBindHost      : SystemString;
    FBindPort      : Word;

    procedure DoConnected(Sender: TObject; AConnection: ICrossConnection); virtual;
    procedure DoDisconnect(Sender: TObject; AConnection: ICrossConnection); virtual;
    procedure DoReceived(Sender: TObject; AConnection: ICrossConnection; ABuf: Pointer; ALen: Integer); virtual;
    procedure DoSent(Sender: TObject; AConnection: ICrossConnection; ABuf: Pointer; ALen: Integer); virtual;
  public
    constructor Create; overload; override;
    constructor Create(maxThPool: Word); overload;
    destructor Destroy; override;

    function StartService(Host: SystemString; Port: Word): Boolean; override;
    procedure StopService; override;

    procedure TriggerQueueData(v: PQueueData); override;
    procedure ProgressBackground; override;

    function WaitSendConsoleCmd(Client: TPeerClient; Cmd: SystemString; ConsoleData: SystemString; TimeOut: TTimeTickValue): SystemString; override;
    procedure WaitSendStreamCmd(Client: TPeerClient; Cmd: SystemString; StreamData, ResultData: TDataFrameEngine; TimeOut: TTimeTickValue); override;

    property StartedService: Boolean read FStartedService;
    property Driver: TDriverEngine read FDriver;
    property BindPort: Word read FBindPort;
    property BindHost: SystemString read FBindHost;
  end;

implementation

procedure TContextIntfForServer.CreateAfter;
begin
  inherited CreateAfter;
  LastActiveTime := GetTimeTickCount;
  Sending := False;
  SendBuffQueue := TCoreClassListForObj.Create;
  CurrentBuff := TMemoryStream64.Create;
end;

destructor TContextIntfForServer.Destroy;
var
  i: Integer;
begin
  for i := 0 to SendBuffQueue.Count - 1 do
      disposeObject(SendBuffQueue[i]);

  disposeObject(SendBuffQueue);

  disposeObject(CurrentBuff);
  inherited Destroy;
end;

function TContextIntfForServer.Context: TCrossConnection;
begin
  Result := ClientIntf as TCrossConnection;
end;

function TContextIntfForServer.Connected: Boolean;
begin
  Result := (ClientIntf <> nil) and
    (Context.ConnectStatus = TConnectStatus.csConnected);
end;

procedure TContextIntfForServer.Disconnect;
begin
  if not Connected then
      exit;
  Context.Close;
end;

procedure TContextIntfForServer.SendBuffResult(AConnection: ICrossConnection; ASuccess: Boolean);
begin
  LastActiveTime := GetTimeTickCount;

  // 为避免使用非页面交换内存，将io内核发送进度同步到主线程来发
  TThread.Synchronize(nil,
    procedure
    var
      i: Integer;
      m: TMemoryStream64;
      isConn: Boolean;
    begin
      isConn := False;
      try
        isConn := Connected;
        if (ASuccess and isConn) then
          begin
            if SendBuffQueue.Count > 0 then
              begin
                m := TMemoryStream64(SendBuffQueue[0]);

                // WSASend吞吐发送时，会复制一份副本，这里有内存拷贝，拷贝限制为32k，已在底层框架做了碎片预裁剪
                // 注意：事件式回调发送的buff总量最后会根据堆栈大小决定
                // 感谢ak47 qq512757165 的测试报告
                Context.SendBuf(m.Memory, m.Size, SendBuffResult);

                // 释放内存
                disposeObject(m);
                // 释放队列
                SendBuffQueue.Delete(0);
              end
            else
              begin
                Sending := False;
              end;
          end
        else
          begin
            // 释放队列空间
            for i := 0 to SendBuffQueue.Count - 1 do
                disposeObject(SendBuffQueue[i]);
            SendBuffQueue.Clear;

            Sending := False;

            if isConn then
                Print('send failed!')
            else
                Print('invailed connected!,send failed!');
            Disconnect;
          end;
      except
        Print('send failed!');
        Disconnect;
      end;
    end);
end;

procedure TContextIntfForServer.SendByteBuffer(const buff: PByte; const Size: NativeInt);
begin
  if not Connected then
      exit;

  LastActiveTime := GetTimeTickCount;

  // 避免大量零碎数据消耗系统资源，这里需要做个碎片收集
  // 在flush中实现精确异步发送和校验
  if Size > 0 then
      CurrentBuff.Write(Pointer(buff)^, Size);
end;

procedure TContextIntfForServer.WriteBufferOpen;
begin
  if not Connected then
      exit;
  LastActiveTime := GetTimeTickCount;
  CurrentBuff.Clear;
end;

procedure TContextIntfForServer.WriteBufferFlush;
var
  ms: TMemoryStream64;
begin
  if not Connected then
      exit;
  LastActiveTime := GetTimeTickCount;

  if Sending then
    begin
      if CurrentBuff.Size > 0 then
        begin
          // 完成优化
          ms := CurrentBuff;
          ms.Position := 0;
          SendBuffQueue.Add(ms);
          CurrentBuff := TMemoryStream64.Create;
        end;
    end
  else
    begin
      // WSASend吞吐发送时，会复制一份副本，这里有内存拷贝，拷贝限制为32k，已在底层框架做了碎片预裁剪
      // 注意：事件式回调发送的buff总量最后会根据堆栈大小决定
      // 感谢ak47 qq512757165 的测试报告
      Sending := True;
      Context.SendBuf(CurrentBuff.Memory, CurrentBuff.Size, SendBuffResult);
      CurrentBuff.Clear;
    end;
end;

procedure TContextIntfForServer.WriteBufferClose;
begin
  if not Connected then
      exit;
  CurrentBuff.Clear;
end;

function TContextIntfForServer.GetPeerIP: SystemString;
begin
  if Connected then
      Result := Context.PeerAddr
  else
      Result := '';
end;

function TContextIntfForServer.WriteBufferEmpty: Boolean;
begin
  Result := not Sending;
end;

procedure TCommunicationFramework_Server_CrossSocket.DoConnected(Sender: TObject; AConnection: ICrossConnection);
var
  cli: TContextIntfForServer;
begin
  TThread.Synchronize(TThread.CurrentThread,
    procedure
    begin
      cli := TContextIntfForServer.Create(Self, AConnection.ConnectionIntf);
      cli.LastActiveTime := GetTimeTickCount;
      AConnection.UserObject := cli;
    end);
end;

procedure TCommunicationFramework_Server_CrossSocket.DoDisconnect(Sender: TObject; AConnection: ICrossConnection);
begin
  TThread.Synchronize(TThread.CurrentThread,
    procedure
    var
      cli: TContextIntfForServer;
    begin
      cli := AConnection.UserObject as TContextIntfForServer;
      if cli <> nil then
        begin
          try
            cli.ClientIntf := nil;
            AConnection.UserObject := nil;
            disposeObject(cli);
          except
          end;
        end;
    end);
end;

procedure TCommunicationFramework_Server_CrossSocket.DoReceived(Sender: TObject; AConnection: ICrossConnection; ABuf: Pointer; ALen: Integer);
begin
  if ALen <= 0 then
      exit;

  if AConnection.UserObject = nil then
      exit;

  TThread.Synchronize(TThread.CurrentThread,
    procedure
    var
      cli: TContextIntfForServer;
    begin
      try
        cli := AConnection.UserObject as TContextIntfForServer;
        if cli.ClientIntf = nil then
            exit;

        cli.LastActiveTime := GetTimeTickCount;
        cli.SaveReceiveBuffer(ABuf, ALen);
        cli.FillRecvBuffer(nil, False, False);
      except
      end;
    end);
end;

procedure TCommunicationFramework_Server_CrossSocket.DoSent(Sender: TObject; AConnection: ICrossConnection; ABuf: Pointer; ALen: Integer);
var
  cli: TContextIntfForServer;
begin
  if AConnection.UserObject = nil then
      exit;

  cli := AConnection.UserObject as TContextIntfForServer;
  if cli.ClientIntf = nil then
      exit;
  cli.LastActiveTime := GetTimeTickCount;
end;

constructor TCommunicationFramework_Server_CrossSocket.Create;
begin
  inherited Create;
  FDriver := TDriverEngine.Create(4);
  FDriver.OnConnected := DoConnected;
  FDriver.OnDisconnected := DoDisconnect;
  FDriver.OnReceived := DoReceived;
  FDriver.OnSent := DoSent;
  FStartedService := False;
  FBindPort := 0;
  FBindHost := '';
end;

constructor TCommunicationFramework_Server_CrossSocket.Create(maxThPool: Word);
begin
  inherited Create;
  FDriver := TDriverEngine.Create(maxThPool);
  FDriver.OnConnected := DoConnected;
  FDriver.OnDisconnected := DoDisconnect;
  FDriver.OnReceived := DoReceived;
  FDriver.OnSent := DoSent;
  FStartedService := False;
  FBindPort := 0;
  FBindHost := '';
end;

destructor TCommunicationFramework_Server_CrossSocket.Destroy;
begin
  StopService;
  try
      disposeObject(FDriver);
  except
  end;
  inherited Destroy;
end;

function TCommunicationFramework_Server_CrossSocket.StartService(Host: SystemString; Port: Word): Boolean;
var
  completed, successed: Boolean;
begin
  StopService;

  completed := False;
  successed := False;
  try
    ICrossSocket(FDriver).Listen(Host, Port,
      procedure(Listen: ICrossListen; ASuccess: Boolean)
      begin
        completed := True;
        successed := ASuccess;
      end);

    while not completed do
        CheckSynchronize(5);

    FBindPort := Port;
    FBindHost := Host;
    Result := successed;
    FStartedService := Result;
  except
      Result := False;
  end;
end;

procedure TCommunicationFramework_Server_CrossSocket.StopService;
begin
  try
    try
        ICrossSocket(FDriver).CloseAll;
    except
    end;
    FStartedService := False;
  except
  end;
end;

procedure TCommunicationFramework_Server_CrossSocket.TriggerQueueData(v: PQueueData);
begin
  (*
    TThread.Synchronize(nil,
    procedure
    begin
    end);
  *)
  if not Exists(v^.Client) then
    begin
      DisposeQueueData(v);
      exit;
    end;

  v^.Client.PostQueueData(v);
  v^.Client.ProcessAllSendCmd(nil, False, False);
end;

procedure TCommunicationFramework_Server_CrossSocket.ProgressBackground;
var
  IDPool: TClientIDPool;
  pid   : Cardinal;
  c     : TContextIntfForServer;
begin
  GetClientIDPool(IDPool);
  try
    for pid in IDPool do
      begin
        c := TContextIntfForServer(ClientFromID[pid]);
        if c <> nil then
          begin
            if (IdleTimeout > 0) and (GetTimeTickCount - c.LastActiveTime > IdleTimeout) then
                c.Disconnect
            else
              begin
                if c.Connected then
                    c.ProcessAllSendCmd(nil, False, False);
              end;
          end;
      end;
  except
  end;

  inherited ProgressBackground;

  CheckSynchronize;
end;

function TCommunicationFramework_Server_CrossSocket.WaitSendConsoleCmd(Client: TPeerClient; Cmd: SystemString; ConsoleData: SystemString; TimeOut: TTimeTickValue): SystemString;
begin
  Result := '';
  RaiseInfo('WaitSend no Suppport CrossSocket');
end;

procedure TCommunicationFramework_Server_CrossSocket.WaitSendStreamCmd(Client: TPeerClient; Cmd: SystemString; StreamData, ResultData: TDataFrameEngine; TimeOut: TTimeTickValue);
begin
  RaiseInfo('WaitSend no Suppport CrossSocket');
end;

initialization

finalization

end.
