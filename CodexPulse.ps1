param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$tracePath=$env:CODEX_PULSE_TRACE
function Write-Trace([string]$Message){if($tracePath){try{Add-Content -LiteralPath $tracePath -Value "$(Get-Date -Format o) $Message"}catch{}}}
Write-Trace 'script loaded'

function ConvertFrom-Base64Url([string]$Value) {
    $padded = $Value.Replace('-', '+').Replace('_', '/')
    while ($padded.Length % 4) { $padded += '=' }
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($padded))
}

function Get-JwtPayload([string]$Token) {
    try { ConvertFrom-Json (ConvertFrom-Base64Url (($Token -split '\.')[1])) } catch { [pscustomobject]@{} }
}

function Get-Plan([string]$Value) {
    $raw = ($Value -replace '[_-]', ' ').Trim().ToLowerInvariant()
    if ($raw -eq 'plus') { return [pscustomobject]@{ Id='plus'; Label='ChatGPT Plus'; Multiplier=1 } }
    if ($raw -match 'pro.*20|20.*pro') { return [pscustomobject]@{ Id='pro-20x'; Label='ChatGPT Pro 20x'; Multiplier=20 } }
    if ($raw -match 'pro.*5|5.*pro') { return [pscustomobject]@{ Id='pro-5x'; Label='ChatGPT Pro 5x'; Multiplier=5 } }
    if ($raw -eq 'pro') { return [pscustomobject]@{ Id='pro'; Label='ChatGPT Pro'; Multiplier=$null } }
    if ($raw -match 'business|team') { return [pscustomobject]@{ Id='business'; Label='ChatGPT Business'; Multiplier=$null } }
    if ($raw -match 'enterprise') { return [pscustomobject]@{ Id='enterprise'; Label='ChatGPT Enterprise'; Multiplier=$null } }
    if ($raw -eq 'free') { return [pscustomobject]@{ Id='free'; Label='ChatGPT Free'; Multiplier=$null } }
    [pscustomobject]@{ Id=if($raw){$raw}else{'unknown'}; Label=if($Value){"ChatGPT $Value"}else{'ChatGPT plan'}; Multiplier=$null }
}

function Get-Credentials {
    $codexRoot = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
    $path = if ($env:CODEX_AUTH_JSON) { $env:CODEX_AUTH_JSON } else { Join-Path $codexRoot 'auth.json' }
    if (!(Test-Path -LiteralPath $path)) { throw 'Codex is not signed in. Open Codex and sign in first.' }
    $document = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
    $tokens = if ($document.tokens) { $document.tokens } else { $document }
    if (!$tokens.access_token) { throw 'Codex auth.json has no access token. Sign in again with Codex.' }
    $claims = Get-JwtPayload $(if($tokens.id_token){$tokens.id_token}else{$tokens.access_token})
    $auth = $claims.'https://api.openai.com/auth'
    [pscustomobject]@{
        AccessToken = $tokens.access_token
        AccountId = if($tokens.account_id){$tokens.account_id}else{$auth.chatgpt_account_id}
        Plan = Get-Plan $auth.chatgpt_plan_type
        CodexRoot = $codexRoot
    }
}

function Get-DurationLabel([double]$Seconds) {
    if (!$Seconds) { return 'Usage window' }
    if ($Seconds % 604800 -eq 0) { $n=$Seconds/604800; return "$n week$(if($n-ne1){'s'})" }
    if ($Seconds % 86400 -eq 0) { $n=$Seconds/86400; return "$n day$(if($n-ne1){'s'})" }
    if ($Seconds % 3600 -eq 0) { $n=$Seconds/3600; return "$n hour$(if($n-ne1){'s'})" }
    "$([math]::Round($Seconds/60)) minutes"
}

function Convert-Window($Window, [string]$Kind, [string]$Resource) {
    if (!$Window) { return $null }
    $usedRaw = if($null-ne$Window.used_percent){$Window.used_percent}else{$Window.usedPercent}
    if ($null -eq $usedRaw) { return $null }
    $used = [math]::Max(0, [math]::Min(100, [double]$usedRaw))
    $seconds = if($Window.limit_window_seconds){[double]$Window.limit_window_seconds}elseif($Window.limitWindowSeconds){[double]$Window.limitWindowSeconds}elseif($Window.window_minutes){[double]$Window.window_minutes*60}elseif($Window.windowMinutes){[double]$Window.windowMinutes*60}else{0}
    $resetRaw = if($Window.reset_at){[double]$Window.reset_at}elseif($Window.resetAt){[double]$Window.resetAt}elseif($Window.resets_at){[double]$Window.resets_at}elseif($Window.resetsAt){[double]$Window.resetsAt}else{0}
    if ($resetRaw -and $resetRaw -lt 1e12) { $resetRaw *= 1000 }
    if (!$resetRaw) {
        $after = if($Window.reset_after_seconds){$Window.reset_after_seconds}else{$Window.resetAfterSeconds}
        if($after){$resetRaw=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()+[double]$after*1000}
    }
    $label = if($Resource){$Resource}elseif($seconds-eq18000){'Five-hour window'}elseif($seconds-eq604800){'Weekly window'}else{Get-DurationLabel $seconds}
    [pscustomobject]@{
        Label=$label
        Detail=if($Resource){"$(Get-DurationLabel $seconds) window"}elseif($Kind-eq'primary'){'Current allowance'}else{'Long-term allowance'}
        UsedPercent=$used
        RemainingPercent=100-$used
        WindowSeconds=$seconds
        ResetAt=$resetRaw
    }
}

function Convert-RateLimit($RateLimit, [string]$Resource) {
    if (!$RateLimit) { return @() }
    $primary = if($RateLimit.primary_window){$RateLimit.primary_window}elseif($RateLimit.primaryWindow){$RateLimit.primaryWindow}else{$RateLimit.primary}
    $secondary = if($RateLimit.secondary_window){$RateLimit.secondary_window}elseif($RateLimit.secondaryWindow){$RateLimit.secondaryWindow}else{$RateLimit.secondary}
    @((Convert-Window $primary 'primary' $Resource),(Convert-Window $secondary 'secondary' $Resource)) | Where-Object { $_ }
}

function Convert-Usage($Value, $FallbackPlan) {
    $rate = if($Value.rate_limit){$Value.rate_limit}else{$Value.rateLimit}
    $limits = [Collections.Generic.List[object]]::new()
    foreach($item in @(Convert-RateLimit $rate $null)){[void]$limits.Add($item)}
    $additional = if($Value.additional_rate_limits){$Value.additional_rate_limits}else{$Value.additionalRateLimits}
    foreach($entry in @($additional)) {
        $name = if($entry.limit_name){$entry.limit_name}elseif($entry.limitName){$entry.limitName}elseif($entry.metered_feature){$entry.metered_feature}elseif($entry.model){$entry.model}else{'Additional limit'}
        $entryRate = if($entry.rate_limit){$entry.rate_limit}else{$entry.rateLimit}
        foreach($item in @(Convert-RateLimit $entryRate $name)){[void]$limits.Add($item)}
    }
    $planRaw = if($Value.plan_type){$Value.plan_type}elseif($Value.planType){$Value.planType}else{$FallbackPlan.Id}
    [pscustomobject]@{Plan=Get-Plan $planRaw; Limits=@($limits); Credits=if($Value.credits){$Value.credits}else{$Value.credit_balance}}
}

function Get-RemoteUsage($Credentials) {
    Add-Type -AssemblyName System.Net.Http
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(12)
    try {
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, 'https://chatgpt.com/backend-api/wham/usage')
        $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Credentials.AccessToken)
        $request.Headers.Accept.ParseAdd('application/json')
        if($Credentials.AccountId){$request.Headers.Add('chatgpt-account-id',$Credentials.AccountId)}
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        if([int]$response.StatusCode -in 401,403){throw 'Codex session expired. Open Codex to refresh your sign-in.'}
        if(!$response.IsSuccessStatusCode){throw "Usage service returned HTTP $([int]$response.StatusCode)."}
        $text=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if($text.Length -gt 1048576){throw 'Usage response was unexpectedly large.'}
        Convert-Usage ($text|ConvertFrom-Json) $Credentials.Plan
    } finally { $client.Dispose(); $handler.Dispose() }
}

function Get-LocalSnapshot($Credentials) {
    $root=Join-Path $Credentials.CodexRoot 'sessions'; $cutoff=(Get-Date).AddDays(-8); $latestRate=$null; $latestStamp=[DateTimeOffset]::MinValue
    $totals=[ordered]@{Input=0L;Cached=0L;Output=0L;Reasoning=0L;Total=0L}; $today=(Get-Date).Date
    if(Test-Path -LiteralPath $root){
        $files=Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.jsonl'|Where-Object LastWriteTime -ge $cutoff|Sort-Object LastWriteTime -Descending|Select-Object -First 200
        foreach($file in $files){$lastUsage=$null;$sessionStamp=$file.LastWriteTime
            foreach($line in Get-Content -LiteralPath $file.FullName){if($line -notmatch 'token_count'){continue};try{$event=$line|ConvertFrom-Json;$payload=$event.payload;if($payload.info.total_token_usage){$lastUsage=$payload.info.total_token_usage};$stamp=[DateTimeOffset]::Parse($event.timestamp);if($stamp.LocalDateTime-gt$sessionStamp){$sessionStamp=$stamp.LocalDateTime};if($payload.rate_limits -and $stamp-gt$latestStamp){$latestRate=$payload.rate_limits;$latestStamp=$stamp}}catch{}}
            if($lastUsage -and $sessionStamp -ge $today){$totals.Input+=[long]$lastUsage.input_tokens;$totals.Cached+=[long]$lastUsage.cached_input_tokens;$totals.Output+=[long]$lastUsage.output_tokens;$totals.Reasoning+=[long]$lastUsage.reasoning_output_tokens;$totals.Total+=[long]$lastUsage.total_tokens}
        }
    }
    $usage=if($latestRate){Convert-Usage ([pscustomobject]@{plan_type=$latestRate.plan_type;rate_limit=$latestRate}) $Credentials.Plan}else{$null}
    [pscustomobject]@{Usage=$usage;Tokens=[pscustomobject]$totals}
}

function Get-Snapshot {
    $credentials=Get-Credentials; $local=Get-LocalSnapshot $credentials; $warning=$null
    try{$usage=Get-RemoteUsage $credentials;$source='Live usage service'}catch{$usage=$local.Usage;$source='Local Codex snapshot';$warning='Live service unavailable; showing the latest usage snapshot written by Codex.'}
    if(!$usage -or !$usage.Limits.Count){throw $(if($warning){$warning}else{'No usage windows yet. Start a Codex task, then refresh.'})}
    $plan=if($usage.Plan.Id-ne'unknown'){$usage.Plan}else{$credentials.Plan};$limits=@($usage.Limits|Sort-Object WindowSeconds)
    $anchor=$limits|Where-Object UsedPercent -gt 1|Select-Object -First 1;$estimate=$null;if($anchor -and $local.Tokens.Total){$estimate=[math]::Round($local.Tokens.Total/$anchor.UsedPercent*$anchor.RemainingPercent)}
    [pscustomobject]@{Plan=$plan;Limits=$limits;Tokens=$local.Tokens;Estimate=$estimate;Source=$source;Warning=$warning;Credits=$usage.Credits}
}

if($SelfTest){
    $sample=[pscustomobject]@{plan_type='pro_5x';rate_limit=[pscustomobject]@{primary_window=[pscustomobject]@{used_percent=30;limit_window_seconds=18000;reset_at=1800000000};secondary_window=[pscustomobject]@{used_percent=60;limit_window_seconds=604800;reset_at=1800100000}}}
    $parsed=Convert-Usage $sample $null
    if($parsed.Plan.Label-ne'ChatGPT Pro 5x' -or $parsed.Limits.Count-ne2 -or $parsed.Limits[0].Label-ne'Five-hour window'){throw 'Parser self-test failed'}
    $live=Get-Snapshot
    Write-Output "PASS: $($live.Plan.Label); $($live.Limits.Count) window(s); source=$($live.Source)"
    exit 0
}

Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms,System.Drawing
[xml]$xaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="Codex Pulse" Width="390" Height="590" MinWidth="350" MinHeight="420" WindowStyle="None" AllowsTransparency="True" Background="Transparent" Topmost="True" ResizeMode="CanResizeWithGrip" ShowInTaskbar="True">
 <Border Background="#0D1113" BorderBrush="#293438" BorderThickness="1" CornerRadius="18">
  <Grid><Grid.RowDefinitions><RowDefinition Height="58"/><RowDefinition Height="*"/><RowDefinition Height="62"/></Grid.RowDefinitions>
   <Border Grid.Row="0" BorderBrush="#293438" BorderThickness="0,0,0,1" Name="TitleBar"><Grid Margin="16,0"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
    <StackPanel Orientation="Horizontal" VerticalAlignment="Center"><Border BorderBrush="#98F7C8" BorderThickness="2" CornerRadius="8" Width="30" Height="30"><TextBlock Text="C" Foreground="#98F7C8" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><StackPanel Margin="10,0,0,0" VerticalAlignment="Center"><TextBlock Text="CODEX PULSE" Foreground="#F1F6F3" FontSize="11" FontWeight="Bold"/><TextBlock Name="Status" Text="CONNECTING" Foreground="#7F8C89" FontSize="9"/></StackPanel></StackPanel>
    <StackPanel Grid.Column="1" Orientation="Horizontal"><Button Name="Compact" Content="-" Width="30" Background="Transparent" BorderThickness="0" Foreground="#7F8C89" FontSize="16"/><Button Name="Close" Content="X" Width="30" Background="Transparent" BorderThickness="0" Foreground="#7F8C89" FontSize="13"/></StackPanel>
   </Grid></Border>
   <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto"><StackPanel Margin="18,18,18,14">
    <Grid Margin="0,0,0,12"><StackPanel><TextBlock Text="ACCOUNT" Foreground="#7F8C89" FontSize="9"/><TextBlock Name="Plan" Text="Detecting plan..." Foreground="#F1F6F3" FontSize="25" FontWeight="SemiBold"/></StackPanel><TextBlock Text="LIVE" Foreground="#98F7C8" FontSize="9" FontWeight="Bold" HorizontalAlignment="Right" VerticalAlignment="Center"/></Grid>
    <StackPanel Name="Limits"/>
    <Border BorderBrush="#293438" BorderThickness="0,1,0,0" Margin="0,12,0,0" Padding="0,12,0,0" Name="Telemetry"><StackPanel><Grid Margin="0,0,0,8"><TextBlock Text="LOCAL TELEMETRY" Foreground="#7F8C89" FontSize="9"/><TextBlock Text="TODAY" Foreground="#7F8C89" FontSize="9" HorizontalAlignment="Right"/></Grid><Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions><Border Background="#141A1D" BorderBrush="#293438" BorderThickness="1" CornerRadius="9" Padding="10" Margin="0,0,4,0"><StackPanel><TextBlock Text="Total processed" Foreground="#7F8C89" FontSize="9"/><TextBlock Name="TotalTokens" Text="-" Foreground="#F1F6F3" FontSize="15" FontWeight="Bold"/></StackPanel></Border><Border Grid.Column="1" Background="#141A1D" BorderBrush="#293438" BorderThickness="1" CornerRadius="9" Padding="10" Margin="4,0,0,0"><StackPanel><TextBlock Text="Cached input" Foreground="#7F8C89" FontSize="9"/><TextBlock Name="CachedTokens" Text="-" Foreground="#F1F6F3" FontSize="15" FontWeight="Bold"/></StackPanel></Border></Grid><Border Background="#141A1D" BorderBrush="#293438" BorderThickness="1" CornerRadius="9" Padding="10" Margin="0,8,0,0"><StackPanel><TextBlock Text="Estimated allowance remaining" Foreground="#7F8C89" FontSize="9"/><TextBlock Name="Estimate" Text="Calibrating..." Foreground="#FFAD55" FontSize="15" FontWeight="Bold"/><TextBlock Text="Rough token-equivalent estimate" Foreground="#7F8C89" FontSize="8"/></StackPanel></Border></StackPanel></Border>
    <TextBlock Name="Notice" Foreground="#D7B980" FontSize="10" TextWrapping="Wrap" Margin="0,10,0,0"/>
   </StackPanel></ScrollViewer>
   <Border Grid.Row="2" BorderBrush="#293438" BorderThickness="0,1,0,0"><Grid Margin="18,0"><StackPanel VerticalAlignment="Center"><TextBlock Name="Source" Text="LOCAL-FIRST" Foreground="#7F8C89" FontSize="8"/><TextBlock Name="Updated" Text="Never updated" Foreground="#7F8C89" FontSize="8"/></StackPanel><Button Name="Refresh" Content="REFRESH" HorizontalAlignment="Right" VerticalAlignment="Center" Padding="10,6" Background="Transparent" BorderBrush="#344044" Foreground="#F1F6F3" FontSize="9"/></Grid></Border>
  </Grid>
 </Border>
</Window>
'@
$reader=[Xml.XmlNodeReader]::new($xaml);$window=[Windows.Markup.XamlReader]::Load($reader)
Write-Trace 'xaml loaded'
foreach($name in 'TitleBar','Status','Compact','Close','Plan','Limits','Telemetry','TotalTokens','CachedTokens','Estimate','Notice','Source','Updated','Refresh') { Set-Variable -Name $name -Value $window.FindName($name) }

function Format-Compact([double]$Value){if($Value-ge1e6){'{0:N1}M'-f($Value/1e6)}elseif($Value-ge1e3){'{0:N1}K'-f($Value/1e3)}else{'{0:N0}'-f$Value}}
function Format-Countdown([double]$Stamp){if(!$Stamp){return'Reset unavailable'};$seconds=[math]::Max(0,[math]::Floor($Stamp/1000-[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()));$d=[math]::Floor($seconds/86400);$h=[math]::Floor(($seconds%86400)/3600);$m=[math]::Floor(($seconds%3600)/60);if($d){"Resets in ${d}d ${h}h"}elseif($h){"Resets in ${h}h ${m}m"}else{"Resets in ${m}m"}}
function New-LimitCard($Limit){$color=if($Limit.UsedPercent-ge90){'#FF756F'}elseif($Limit.UsedPercent-ge70){'#FFAD55'}else{'#98F7C8'};$card=[Windows.Controls.Border]::new();$card.Background='#141A1D';$card.BorderBrush='#293438';$card.BorderThickness=1;$card.CornerRadius=10;$card.Padding=12;$card.Margin='0,4,0,4';$stack=[Windows.Controls.StackPanel]::new();$top=[Windows.Controls.Grid]::new();$left=[Windows.Controls.StackPanel]::new();$a=[Windows.Controls.TextBlock]::new();$a.Text=$Limit.Label;$a.Foreground='#F1F6F3';$a.FontWeight='SemiBold';$b=[Windows.Controls.TextBlock]::new();$b.Text=$Limit.Detail.ToUpperInvariant();$b.Foreground='#7F8C89';$b.FontSize=8;[void]$left.Children.Add($a);[void]$left.Children.Add($b);$pct=[Windows.Controls.TextBlock]::new();$pct.Text="$([math]::Round($Limit.RemainingPercent))%";$pct.Foreground=$color;$pct.FontSize=18;$pct.FontWeight='Bold';$pct.HorizontalAlignment='Right';[void]$top.Children.Add($left);[void]$top.Children.Add($pct);$bar=[Windows.Controls.ProgressBar]::new();$bar.Value=$Limit.UsedPercent;$bar.Maximum=100;$bar.Height=7;$bar.Foreground=$color;$bar.Background='#263034';$bar.Margin='0,10,0,8';$foot=[Windows.Controls.Grid]::new();$used=[Windows.Controls.TextBlock]::new();$used.Text="$([math]::Round($Limit.UsedPercent))% USED";$used.Foreground='#7F8C89';$used.FontSize=8;$reset=[Windows.Controls.TextBlock]::new();$reset.Text=Format-Countdown $Limit.ResetAt;$reset.Foreground='#B7C2BF';$reset.FontSize=8;$reset.HorizontalAlignment='Right';[void]$foot.Children.Add($used);[void]$foot.Children.Add($reset);[void]$stack.Children.Add($top);[void]$stack.Children.Add($bar);[void]$stack.Children.Add($foot);$card.Child=$stack;$card}
function Refresh-Ui{$Status.Text='REFRESHING';$Refresh.IsEnabled=$false;try{$data=Get-Snapshot;$Plan.Text=$data.Plan.Label;$Status.Text=$data.Source.ToUpperInvariant();$Limits.Children.Clear();foreach($limit in $data.Limits){$card=New-LimitCard $limit;[void]$Limits.Children.Add($card)};$TotalTokens.Text=Format-Compact $data.Tokens.Total;$CachedTokens.Text=Format-Compact $data.Tokens.Cached;$Estimate.Text=if($data.Estimate){"~ $(Format-Compact $data.Estimate) tokens"}else{'Calibrating...'};$Source.Text=$data.Source.ToUpperInvariant();$Updated.Text="Updated $(Get-Date -Format HH:mm)";$Notice.Text=if($data.Warning){$data.Warning}else{'Token remainder is a rough estimate; OpenAI dynamically meters model, context, reasoning, and tools.'};$Notice.Foreground='#D7B980'}catch{Write-Trace "refresh failed: $($_.Exception.Message) :: $($_.ScriptStackTrace)";$Status.Text='ATTENTION';$Notice.Text=$_.Exception.Message;$Notice.Foreground='#FF756F'}finally{$Refresh.IsEnabled=$true}}
$TitleBar.Add_MouseLeftButtonDown({$window.DragMove()});$Close.Add_Click({$window.Hide()});$Refresh.Add_Click({Refresh-Ui});$compactMode=$false;$Compact.Add_Click({$script:compactMode=!$script:compactMode;if($script:compactMode){$Telemetry.Visibility='Collapsed';$Notice.Visibility='Collapsed';$window.Height=280}else{$Telemetry.Visibility='Visible';$Notice.Visibility='Visible';$window.Height=590}})
$tray=[Windows.Forms.NotifyIcon]::new();$tray.Text='Codex Pulse';$tray.Icon=[Drawing.SystemIcons]::Information;$tray.Visible=$true;$menu=[Windows.Forms.ContextMenuStrip]::new();[void]$menu.Items.Add('Show Codex Pulse',$null,{$window.Show();$window.Activate()});[void]$menu.Items.Add('Refresh now',$null,{$window.Dispatcher.Invoke([action]{Refresh-Ui})});[void]$menu.Items.Add('Quit',$null,{$script:quitting=$true;$tray.Visible=$false;$window.Close()});$tray.ContextMenuStrip=$menu;$tray.Add_DoubleClick({$window.Show();$window.Activate()});$window.Add_Closing({param($s,$e)if(!$script:quitting){$e.Cancel=$true;$window.Hide()}})
$timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMinutes(1);$timer.Add_Tick({Refresh-Ui});$timer.Start();$window.Add_ContentRendered({Write-Trace 'content rendered';if(!$script:loaded){$script:loaded=$true;$window.Dispatcher.BeginInvoke([action]{Refresh-Ui})|Out-Null}})
if($env:CODEX_PULSE_CAPTURE){$captureTimer=[Windows.Threading.DispatcherTimer]::new();$captureTimer.Interval=[TimeSpan]::FromSeconds(5);$captureTimer.Add_Tick({$captureTimer.Stop();$bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]$window.ActualWidth,[int]$window.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($window);$encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap));$stream=[IO.File]::Open($env:CODEX_PULSE_CAPTURE,[IO.FileMode]::Create);try{$encoder.Save($stream)}finally{$stream.Dispose()};$script:quitting=$true;$window.Close()});$captureTimer.Start()}
Write-Trace 'showing window';[void]$window.ShowDialog();Write-Trace 'window closed';$tray.Dispose()
