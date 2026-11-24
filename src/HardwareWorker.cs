using LibreHardwareMonitor.Hardware;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace LHMService;

public sealed class HardwareWorker : BackgroundService
{
    private readonly ILogger<HardwareWorker> _logger;
    private readonly int _port;
    private readonly int _pollIntervalSeconds;

    private volatile string _lastJson = "[]";

    private static readonly JsonSerializerOptions _jsonOptions = new()
    {
        WriteIndented          = false,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public HardwareWorker(ILogger<HardwareWorker> logger, IConfiguration config)
    {
        _logger              = logger;
        _port                = config.GetValue("LHMService:Port", 8085);
        _pollIntervalSeconds = config.GetValue("LHMService:PollIntervalSeconds", 5);
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        _logger.LogInformation("LibreHardwareMonitor service starting");

        var computer = new Computer
        {
            IsCpuEnabled         = true,
            IsGpuEnabled         = true,
            IsMemoryEnabled      = true,
            IsMotherboardEnabled = true,
            IsStorageEnabled     = true,
            IsNetworkEnabled     = true,
            IsControllerEnabled  = true,
        };

        computer.Open();
        _logger.LogInformation("Hardware opened. Found {Count} device(s)", computer.Hardware.Count);

        var listener = new HttpListener();
        listener.Prefixes.Add($"http://localhost:{_port}/");
        listener.Prefixes.Add($"http://127.0.0.1:{_port}/");
        listener.Start();
        _logger.LogInformation("HTTP endpoint listening on port {Port}", _port);

        var httpTask = HandleHttpAsync(listener, stoppingToken);

        try
        {
            while (!stoppingToken.IsCancellationRequested)
            {
                foreach (var hw in computer.Hardware)
                {
                    hw.Update();
                    foreach (var sub in hw.SubHardware)
                        sub.Update();
                }
                _lastJson = BuildJson(computer);

                await Task.Delay(TimeSpan.FromSeconds(_pollIntervalSeconds), stoppingToken);
            }
        }
        catch (OperationCanceledException) { }
        finally
        {
            listener.Stop();
            computer.Close();
            _logger.LogInformation("LibreHardwareMonitor service stopped");
        }

        await httpTask;
    }

    // ── HTTP ───────────────────────────────────────────────────────────────

    private async Task HandleHttpAsync(HttpListener listener, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested && listener.IsListening)
        {
            HttpListenerContext ctx;
            try { ctx = await listener.GetContextAsync().WaitAsync(ct); }
            catch { break; }
            _ = Task.Run(() => RespondAsync(ctx, ct), ct);
        }
    }

    private async Task RespondAsync(HttpListenerContext ctx, CancellationToken ct)
    {
        var path = ctx.Request.Url?.AbsolutePath.TrimEnd('/') ?? "/";

        string body;
        int    status = 200;

        switch (path)
        {
            case "" or "/" or "/api" or "/api/hardware":
                body = _lastJson;
                break;
            case "/health":
                body = "{\"status\":\"ok\"}";
                break;
            default:
                body   = "{\"error\":\"not found\"}";
                status = 404;
                break;
        }

        ctx.Response.StatusCode  = status;
        ctx.Response.ContentType = "application/json; charset=utf-8";
        ctx.Response.AddHeader("Cache-Control", "no-cache");

        var bytes = Encoding.UTF8.GetBytes(body);
        ctx.Response.ContentLength64 = bytes.Length;
        try
        {
            await ctx.Response.OutputStream.WriteAsync(bytes, ct);
        }
        catch { }
        finally { ctx.Response.Close(); }
    }

    // ── JSON ───────────────────────────────────────────────────────────────

    private string BuildJson(Computer computer)
    {
        var list = computer.Hardware.Select(SerializeHardware).ToList();
        return JsonSerializer.Serialize(list, _jsonOptions);
    }

    private static HardwareDto SerializeHardware(IHardware hw) => new()
    {
        Name        = hw.Name,
        Type        = hw.HardwareType.ToString(),
        Identifier  = hw.Identifier.ToString(),
        Sensors     = hw.Sensors.Select(s => new SensorDto
        {
            Identifier = s.Identifier.ToString(),
            Name       = s.Name,
            Type       = s.SensorType.ToString(),
            Value      = s.Value.HasValue ? (double?)Math.Round((double)s.Value.Value, 2) : null,
            Min        = s.Min.HasValue   ? (double?)Math.Round((double)s.Min.Value,   2) : null,
            Max        = s.Max.HasValue   ? (double?)Math.Round((double)s.Max.Value,   2) : null,
        }).ToList(),
        SubHardware = hw.SubHardware.Select(SerializeHardware).ToList(),
    };

    private sealed record HardwareDto
    {
        [JsonPropertyName("name")]        public string            Name        { get; init; } = "";
        [JsonPropertyName("type")]        public string            Type        { get; init; } = "";
        [JsonPropertyName("identifier")]  public string            Identifier  { get; init; } = "";
        [JsonPropertyName("sensors")]     public List<SensorDto>   Sensors     { get; init; } = [];
        [JsonPropertyName("subHardware")] public List<HardwareDto> SubHardware { get; init; } = [];
    }

    private sealed record SensorDto
    {
        [JsonPropertyName("identifier")] public string  Identifier { get; init; } = "";
        [JsonPropertyName("name")]       public string  Name       { get; init; } = "";
        [JsonPropertyName("type")]       public string  Type       { get; init; } = "";
        [JsonPropertyName("value")]      public double? Value      { get; init; }
        [JsonPropertyName("min")]        public double? Min        { get; init; }
        [JsonPropertyName("max")]        public double? Max        { get; init; }
    }
}
