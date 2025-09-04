using Microsoft.AspNetCore.Mvc;
using System.Text;
using System.Text.Json;
using Serilog;
using Serilog.Events;


// Configure Serilog from appsettings.json
Log.Logger = new LoggerConfiguration()
    .ReadFrom.Configuration(new ConfigurationBuilder()
        .AddJsonFile("appsettings.json")
        .AddJsonFile($"appsettings.{Environment.GetEnvironmentVariable("ASPNETCORE_ENVIRONMENT") ?? "Production"}.json", optional: true)
        .Build())
    .CreateLogger();

var builder = WebApplication.CreateBuilder(args);

// Replace default logging with Serilog
builder.Host.UseSerilog();

// Configure URLs (optional - can be set via config instead)
// builder.WebHost.UseUrls("http://localhost:3000", "https://localhost:3001");

// Ensure logs directory exists
Directory.CreateDirectory("logs");

// Add services to the container
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen();
builder.Services.AddControllers();

// Add request/response logging service
builder.Services.AddSingleton<IRequestResponseLogger, RequestResponseLogger>();

var app = builder.Build();

// Add request/response logging middleware
app.UseMiddleware<RequestResponseLoggingMiddleware>();

// Configure the HTTP request pipeline
if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI();
}

app.UseHttpsRedirection();
app.MapControllers();

// Simple endpoint for health check
app.MapGet("/", (ILogger<Program> logger) => {
    logger.LogInformation("Health check endpoint accessed");
    return "Hello World! API is running.";
});

app.Run();

// Weather forecast model
public record WeatherForecast(DateOnly Date, int TemperatureC, string? Summary)
{
    public int TemperatureF => 32 + (int)(TemperatureC / 0.5556);
}

// Weather controller
[ApiController]
[Route("api/[controller]")]
public class WeatherController : ControllerBase
{
    private static readonly string[] Summaries = new[]
    {
        "Freezing", "Bracing", "Chilly", "Cool", "Mild", "Warm", "Balmy", "Hot", "Sweltering", "Scorching"
    };

    private readonly ILogger<WeatherController> _logger;

    public WeatherController(ILogger<WeatherController> logger)
    {
        _logger = logger;
    }

    [HttpGet]
    public IEnumerable<WeatherForecast> Get()
    {
        _logger.LogInformation("Getting weather forecasts for 5 days");
        
        var forecasts = Enumerable.Range(1, 5).Select(index => new WeatherForecast
        (
            DateOnly.FromDateTime(DateTime.Now.AddDays(index)),
            Random.Shared.Next(-20, 55),
            Summaries[Random.Shared.Next(Summaries.Length)]
        ))
        .ToArray();

        _logger.LogInformation("Returning {Count} weather forecasts", forecasts.Length);
        return forecasts;
    }

    [HttpGet("{id}")]
    public ActionResult<WeatherForecast> Get(int id)
    {
        _logger.LogInformation("Getting weather forecast for day {Id}", id);
        
        if (id < 1 || id > 10)
        {
            _logger.LogWarning("Invalid weather forecast ID requested: {Id}", id);
            return NotFound();
        }

        var forecast = new WeatherForecast
        (
            DateOnly.FromDateTime(DateTime.Now.AddDays(id)),
            Random.Shared.Next(-20, 55),
            Summaries[Random.Shared.Next(Summaries.Length)]
        );

        _logger.LogInformation("Returning weather forecast for day {Id}: {Temperature}°C, {Summary}", 
            id, forecast.TemperatureC, forecast.Summary);

        return forecast;
    }
}

// Request/Response Logger Interface
public interface IRequestResponseLogger
{
    Task LogAsync(string method, string path, string? requestBody, string? responseBody, int statusCode, TimeSpan duration);
}

// Request/Response Logger Implementation
public class RequestResponseLogger : IRequestResponseLogger
{
    private readonly string _logFilePath;
    private readonly SemaphoreSlim _semaphore;
    private readonly string _serverName;

    public RequestResponseLogger()
    {
        var logsDirectory = "logs";
        Directory.CreateDirectory(logsDirectory);
        _logFilePath = Path.Combine(logsDirectory, $"requests-responses-{DateTime.Now:yyyy-MM-dd}.txt");
        _semaphore = new SemaphoreSlim(1, 1);
        
        // Get server/container name from multiple sources
        _serverName = GetServerName();
    }

    private string GetServerName()
    {
        // Try to get container name first (Docker environment)
        var containerName = Environment.GetEnvironmentVariable("HOSTNAME") ?? 
                           Environment.GetEnvironmentVariable("COMPUTERNAME") ?? 
                           Environment.GetEnvironmentVariable("CONTAINER_NAME");
        
        if (!string.IsNullOrWhiteSpace(containerName))
        {
            return $"Container: {containerName}";
        }
        
        // Fall back to machine name
        try
        {
            return $"Server: {Environment.MachineName}";
        }
        catch
        {
            return "Server: Unknown";
        }
    }

    public async Task LogAsync(string method, string path, string? requestBody, string? responseBody, int statusCode, TimeSpan duration)
    {
        await _semaphore.WaitAsync();
        try
        {
            var logEntry = new StringBuilder();
            logEntry.AppendLine($"=== {DateTime.UtcNow:yyyy-MM-dd HH:mm:ss} UTC ===");
            logEntry.AppendLine($"Server: {_serverName}");
            logEntry.AppendLine($"Method: {method}");
            logEntry.AppendLine($"Path: {path}");
            logEntry.AppendLine($"Status Code: {statusCode}");
            logEntry.AppendLine($"Duration: {duration.TotalMilliseconds:F2} ms");
            
            if (!string.IsNullOrWhiteSpace(requestBody))
            {
                logEntry.AppendLine($"Request Body: {requestBody}");
            }
            
            if (!string.IsNullOrWhiteSpace(responseBody))
            {
                logEntry.AppendLine($"Response Body: {responseBody}");
            }
            
            logEntry.AppendLine();

            await File.AppendAllTextAsync(_logFilePath, logEntry.ToString());
        }
        finally
        {
            _semaphore.Release();
        }
    }
}

// Request/Response Logging Middleware
public class RequestResponseLoggingMiddleware
{
    private readonly RequestDelegate _next;
    private readonly IRequestResponseLogger _logger;
    private readonly ILogger<RequestResponseLoggingMiddleware> _appLogger;

    public RequestResponseLoggingMiddleware(RequestDelegate next, IRequestResponseLogger logger, ILogger<RequestResponseLoggingMiddleware> appLogger)
    {
        _next = next;
        _logger = logger;
        _appLogger = appLogger;
    }

    public async Task InvokeAsync(HttpContext context)
    {
        var startTime = DateTime.UtcNow;
        
        // Read request body
        string? requestBody = null;
        if (context.Request.ContentLength > 0)
        {
            context.Request.EnableBuffering();
            using var reader = new StreamReader(context.Request.Body, Encoding.UTF8, leaveOpen: true);
            requestBody = await reader.ReadToEndAsync();
            context.Request.Body.Position = 0;
        }

        // Capture response
        var originalResponseBody = context.Response.Body;
        using var responseBodyStream = new MemoryStream();
        context.Response.Body = responseBodyStream;

        try
        {
            await _next(context);
        }
        catch (Exception ex)
        {
            _appLogger.LogError(ex, "Unhandled exception occurred during request processing");
            throw;
        }

        // Read response body
        var duration = DateTime.UtcNow - startTime;
        responseBodyStream.Seek(0, SeekOrigin.Begin);
        var responseBody = await new StreamReader(responseBodyStream).ReadToEndAsync();
        responseBodyStream.Seek(0, SeekOrigin.Begin);

        // Copy response back to original stream
        await responseBodyStream.CopyToAsync(originalResponseBody);

        // Log the request/response
        await _logger.LogAsync(
            context.Request.Method,
            context.Request.Path + context.Request.QueryString,
            requestBody,
            responseBody,
            context.Response.StatusCode,
            duration
        );

        _appLogger.LogInformation("Request {Method} {Path} completed with status {StatusCode} in {Duration:F2}ms",
            context.Request.Method,
            context.Request.Path,
            context.Response.StatusCode,
            duration.TotalMilliseconds);
    }
}