using LHMService;

var builder = Host.CreateApplicationBuilder(args);

builder.Services.AddWindowsService(options =>
{
    options.ServiceName = "LibreHardwareMonitor";
});

builder.Logging.AddEventLog(settings =>
{
    settings.SourceName = "LibreHardwareMonitor";
    settings.LogName    = "Application";
});

builder.Services.AddSingleton<IConfiguration>(builder.Configuration);
builder.Services.AddHostedService<HardwareWorker>();

var host = builder.Build();
host.Run();
