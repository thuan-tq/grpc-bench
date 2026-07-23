// Copyright 2024 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package main

import (
    "bytes"
    "context"
    "errors"
    "flag"
    "fmt"
    "io"
    "log"
    "math/rand"
    "net/http"
    _ "net/http/pprof"
    "slices"
    "sort"
    "strconv"
    "strings"
    "sync"
    "time"

    "cloud.google.com/go/storage"
    "cloud.google.com/go/storage/experimental"
    "github.com/google/uuid"
    "google.golang.org/api/googleapi"
    "google.golang.org/api/option"
    "google.golang.org/grpc"

    // Install google-c2p resolver, which is required for direct path.
    _ "google.golang.org/grpc/xds/googledirectpath"

    // Install RLS load balancer policy, which is needed for gRPC RLS.
    _ "google.golang.org/grpc/balancer/rls"
)

const (
    JSON       = "JSON"
    GRPC_DP    = "GRPC+DP"
    rapid      = "RAPID"
    regional   = "REGIONAL"
    singleShot = "SINGLE-SHOT"
    resumable  = "RESUMABLE"
    appendable = "APPENDABLE"
    KiB        = 1024
    MiB        = 1024 * KiB
    // The minimum upload quantum supported by Google Cloud Storage
    uploadQuantum = 256 * KiB
)

func main() {
    var projectID = flag.String("project-id", "", "the Google Cloud Platform project")
    var bucket = flag.String("bucket", "", "the bucket used by the benchmark")
    var transportArgs stringFlags
    flag.Var(&transportArgs, "transport", "the transports (JSON, GRPC+DP) used by the benchmark")
    var iterations = flag.Int("iterations", 100, "how many iterations to run")
    var workers = flag.Int("workers", 1, "the number of concurrent threads running the benchmark")
    var uploaderArgs stringFlags
    flag.Var(&uploaderArgs, "uploader", "the uploaders (SINGLE-SHOT) used by the benchmark")
    var objectSizes intFlags
    flag.Var(&objectSizes, "object-size", "the object sizes used by the benchmark")
    var writeBufSize = flag.Int("write-buffer-size", -1, "gRPC WriteBufferSize in bytes (-1 for default)")
    var readBufSize = flag.Int("read-buffer-size", -1, "gRPC ReadBufferSize in bytes (-1 for default)")
    var warmupIterations = flag.Int("warmup-iterations", 0, "number of warmup iterations to run before recording results")
    var pprofAddr = flag.String("pprof-addr", "", "address to serve pprof on (e.g. localhost:6060); disabled if empty")

    // NEW FLAG CONFIGURATION
    var testDownload = flag.Bool("test-download", false, "measure download throughput instead of upload")
    var downloadObjectName = flag.String("download-object", "", "if set with -test-download, skips upload setup and loops downloading this existing object instead")

    flag.Parse()

    if *projectID == "" {
        flag.Usage()
        log.Fatal("-project-id is required")
    }
    if *bucket == "" {
        flag.Usage()
        log.Fatal("-bucket is required")
    }

    if len(transportArgs) == 0 {
        transportArgs = append(transportArgs, JSON)
    } else {
        for _, t := range transportArgs {
            if t != JSON && t != GRPC_DP {
                log.Fatalf("Unsupported transport: %s. Only JSON and GRPC+DP are supported.", t)
            }
        }
    }

    if len(uploaderArgs) == 0 {
        uploaderArgs = append(uploaderArgs, singleShot)
    } else {
        for _, u := range uploaderArgs {
            if u != singleShot {
                log.Fatalf("Unsupported uploader: %s. Only SINGLE-SHOT is supported.", u)
            }
        }
    }

    if len(objectSizes) == 0 {
        objectSizes = append(objectSizes, 2*MiB)
    }

    appName := "ssb::simplified"
    log.Printf("## Starting continuous GCS Go SDK %v benchmark", appName)
    if *pprofAddr != "" {
        go func() {
            log.Printf("pprof server listening on %s", *pprofAddr)
            log.Println(http.ListenAndServe(*pprofAddr, nil))
        }()
    }
    instance, err := uuid.NewRandom()
    if err != nil {
        log.Fatalf("Cannot create instance name %v", err)
    }

    ctx := context.Background()

    clients, err := makeClients(ctx, transportArgs, *writeBufSize, *readBufSize)
    if err != nil {
        log.Fatalf("Error creating transports: %v", err)
    }

    closeClients := func() {
        for _, t := range clients {
            t.client.Close()
        }
    }
    defer closeClients()

    bucketType, bucketLocation, err := fetchBucketAttrs(clients[0].client, *bucket)
    if err != nil {
        log.Fatalf("Error getting bucket type: %v", err)
    }

    uploaders, err := makeUploaders(uploaderArgs, bucketType)
    if err != nil {
        log.Fatalf("Error creating uploaders: %v", err)
    }

    log.Printf("# object-sizes: %v", objectSizes)
    log.Printf("# transports: %v", transportArgs)
    log.Printf("# uploaders: %v", uploaderArgs)
    log.Printf("# writeBufSize: %v", *writeBufSize)
    log.Printf("# readBufSize: %v", *readBufSize)
    log.Printf("# project-id: %s", *projectID)
    log.Printf("# bucket: %s", *bucket)
    log.Printf("# bucketType: %s", bucketType)
    log.Printf("# bucketLocation: %s", bucketLocation)
    log.Printf("# instance: %s", instance.String())
    log.Printf("# Workers: %d", *workers)
    log.Printf("# Iterations: %d", *iterations)
    log.Printf("# Warmup Iterations: %d", *warmupIterations)
    log.Printf("# Test Download: %t", *testDownload)

    config := BenchmarkConfig{
        clients:          clients,
        uploaders:        uploaders,
        bucketType:       bucketType,
        bucketLocation:   bucketLocation,
        objectSizes:      objectSizes,
        bucketName:       *bucket,
        instance:         instance.String(),
        iterations:       *iterations,
        warmupIterations: *warmupIterations,
        testDownload:     *testDownload,
        downloadObject:   *downloadObjectName,
    }

    var wg sync.WaitGroup
    runWorkload := func() {
        defer wg.Done()
        w1r3Worker(ctx, &config)
    }

    wg.Add(*workers)
    for range *workers {
        go runWorkload()
    }
    wg.Wait()
    log.Println("Benchmark finished.")
}

type BenchmarkConfig struct {
    clients          []Transport
    uploaders        []Uploader
    objectSizes      []int64
    bucketName       string
    bucketType       string
    bucketLocation   string
    instance         string
    iterations       int
    warmupIterations int
    testDownload     bool
    downloadObject   string
}

type Transport struct {
    transport   string
    client      *storage.Client
    bidiEnabled bool
}

func (t Transport) isGRPC() bool {
    return t.transport == GRPC_DP
}

func makeClients(ctx context.Context, flags []string, writeBufSize, readBufSize int) ([]Transport, error) {
    var transports = make([]Transport, 0)

    for _, transport := range flags {
        switch transport {
        case JSON:
            client, err := storage.NewClient(ctx)
            if err != nil {
                return nil, err
            }
            transports = append(transports, Transport{transport: transport, client: client})
        case GRPC_DP:
            grpcOpts := []option.ClientOption{
                storage.WithDisabledClientMetrics(),
            }
            if writeBufSize > 0 {
                grpcOpts = append(grpcOpts, option.WithGRPCDialOption(grpc.WithWriteBufferSize(writeBufSize)))
            }
            if readBufSize > 0 {
                grpcOpts = append(grpcOpts, option.WithGRPCDialOption(grpc.WithReadBufferSize(readBufSize)))
            }
            client, err := storage.NewGRPCClient(ctx, grpcOpts...)
            if err != nil {
                return nil, err
            }
            transports = append(transports, Transport{transport: transport, client: client, bidiEnabled: false})

            // Bidi-enabled client
            bidiOpts := append(grpcOpts, experimental.WithGRPCBidiReads())
            bidiClient, err := storage.NewGRPCClient(ctx, bidiOpts...)
            if err != nil {
                return nil, err
            }
            transports = append(transports, Transport{transport: transport, client: bidiClient, bidiEnabled: true})
        default:
            return nil, fmt.Errorf("unknown transport %v", transport)
        }
    }
    return transports, nil
}

func w1r3Worker(ctx context.Context, config *BenchmarkConfig) {
    data := make([]byte, slices.Max(config.objectSizes))
    rand.Read(data)

    for _, client := range config.clients {
        if client.bidiEnabled { // Skip bidi clients for this test
            continue
        }

        // For download tests without a pre-existing object, upload one object
        // once and reuse it across all iterations. This isolates the download
        // measurement from per-iteration upload noise.
        var sharedDownloadHandle *storage.ObjectHandle
        var sharedDownloadName string
        if config.testDownload && config.downloadObject == "" {
            id, err := uuid.NewRandom()
            if err != nil {
                log.Printf("ERROR: Failed to generate UUID for download setup: %v", err)
                continue
            }
            sharedDownloadName = id.String()
            objectSize := config.objectSizes[rand.Intn(len(config.objectSizes))]
            uploader := config.uploaders[rand.Intn(len(config.uploaders))]
            handle, _, err := uploadStep(ctx, config, uploader, client, sharedDownloadName, data[0:objectSize])
            if err != nil {
                log.Printf("ERROR: Download-test setup upload failed for %s using %s: %v", sharedDownloadName, client.transport, err)
                continue
            }
            sharedDownloadHandle = handle
            log.Printf("Download-test setup: uploaded %s (%d bytes) via %s", sharedDownloadName, objectSize, client.transport)
        }

        totalIterations := config.warmupIterations + config.iterations
        uploadLatencies := make([]time.Duration, 0, config.iterations)
        downloadLatencies := make([]time.Duration, 0, config.iterations)

        for i := range totalIterations {
            warmup := i < config.warmupIterations
            var objectName string
            var objectHandle *storage.ObjectHandle

            // 1. Object Setup Phase
            // - Download test with pre-existing object: use it, no upload/delete
            // - Download test with shared upload: reuse the setup object
            // - Upload test: fresh upload per iteration, deleted after
            if config.testDownload && config.downloadObject != "" {
                objectName = config.downloadObject
            } else if config.testDownload {
                objectName = sharedDownloadName
            } else {
                id, err := uuid.NewRandom()
                if err != nil {
                    log.Printf("Warning: Failed to generate UUID: %v", err)
                    continue
                }
                objectName = id.String()
                objectSize := config.objectSizes[rand.Intn(len(config.objectSizes))]
                uploader := config.uploaders[rand.Intn(len(config.uploaders))]

                var upDuration time.Duration
                objectHandle, upDuration, err = uploadStep(ctx, config, uploader, client, objectName, data[0:objectSize])
                if err != nil {
                    log.Printf("ERROR: Upload step setup failed for %s using %s: %v", objectName, client.transport, err)
                    continue
                }

                if !warmup {
                    uploadLatencies = append(uploadLatencies, upDuration)
                }
            }

            // 2. Download Phase
            if config.testDownload {
                downDuration, err := downloadStep(ctx, client.client, config.bucketName, objectName)
                if err != nil {
                    log.Printf("ERROR: Download step failed for %s using %s: %v", objectName, client.transport, err)
                } else if !warmup {
                    downloadLatencies = append(downloadLatencies, downDuration)
                }
            }

            // 3. Cleanup Phase (only for upload tests where we uploaded per-iteration)
            if objectHandle != nil {
                d := objectHandle.Retryer(storage.WithPolicy(storage.RetryAlways))
                if err := d.Delete(ctx); err != nil {
                    log.Printf("WARN: Failed to delete object %s: %v", objectName, err)
                }
            }
        }

        // Delete the shared download-test object after all iterations complete.
        if sharedDownloadHandle != nil {
            d := sharedDownloadHandle.Retryer(storage.WithPolicy(storage.RetryAlways))
            if err := d.Delete(ctx); err != nil {
                log.Printf("WARN: Failed to delete shared download object %s: %v", sharedDownloadName, err)
            }
        }

        // Print Results depending on current operating mode
        if !config.testDownload && len(uploadLatencies) > 0 {
            sort.Slice(uploadLatencies, func(i, j int) bool { return uploadLatencies[i] < uploadLatencies[j] })
            avgLatency := calculateAverage(uploadLatencies)
            p90Latency := calculatePercentile(uploadLatencies, 90)
            p99Latency := calculatePercentile(uploadLatencies, 99)
            fmt.Printf("\n--- Benchmark Results for --- %s [UPLOAD]\n", client.transport)
            fmt.Printf("Average Latency: %v\n", avgLatency.Round(time.Microsecond))
            fmt.Printf("P90 Latency:     %v\n", p90Latency.Round(time.Microsecond))
            fmt.Printf("P99 Latency:     %v\n", p99Latency.Round(time.Microsecond))
        } else if !config.testDownload {
            fmt.Printf("\n--- No successful upload runs for --- %s\n", client.transport)
        }

        if config.testDownload && len(downloadLatencies) > 0 {
            sort.Slice(downloadLatencies, func(i, j int) bool { return downloadLatencies[i] < downloadLatencies[j] })
            avgLatency := calculateAverage(downloadLatencies)
            p90Latency := calculatePercentile(downloadLatencies, 90)
            p99Latency := calculatePercentile(downloadLatencies, 99)
            fmt.Printf("\n--- Benchmark Results for --- %s [DOWNLOAD]\n", client.transport)
            fmt.Printf("Average Latency: %v\n", avgLatency.Round(time.Microsecond))
            fmt.Printf("P90 Latency:     %v\n", p90Latency.Round(time.Microsecond))
            fmt.Printf("P99 Latency:     %v\n", p99Latency.Round(time.Microsecond))
        }
    }
}

func calculateAverage(latencies []time.Duration) time.Duration {
    var total time.Duration
    if len(latencies) == 0 {
        return 0
    }
    for _, lat := range latencies {
        total += lat
    }
    return total / time.Duration(len(latencies))
}

func calculatePercentile(latencies []time.Duration, percentile float64) time.Duration {
    if len(latencies) == 0 {
        return 0
    }
    index := float64(len(latencies)-1) * (percentile / 100.0)
    lower := int(index)
    upper := lower + 1

    if upper >= len(latencies) {
        return latencies[lower]
    }

    weight := index - float64(lower)
    return latencies[lower] + time.Duration(float64(latencies[upper]-latencies[lower])*weight)
}

func uploadStep(ctx context.Context,
    config *BenchmarkConfig,
    uploader Uploader,
    client Transport,
    objectName string,
    data []byte,
) (*storage.ObjectHandle, time.Duration, error) {
    start := time.Now()
    objectHandle, err := uploader.upload(ctx, client.client, config.bucketName, objectName, data)
    if err != nil {
        return nil, 0, err
    }
    duration := time.Since(start)
    return objectHandle, duration, nil
}

func downloadStep(ctx context.Context, client *storage.Client, bucketName string, objectName string) (time.Duration, error) {
    start := time.Now()
    reader, err := client.Bucket(bucketName).Object(objectName).NewReader(ctx)
    if err != nil {
        return 0, err
    }
    defer reader.Close()

    // Drain the payload pulling it entirely down the network to measure GCS receiver pipeline
    if _, err := io.Copy(io.Discard, reader); err != nil {
        return 0, err
    }

    return time.Since(start), nil
}

type Uploader struct {
    name   string
    upload func(ctx context.Context, client *storage.Client,
        bucketName string, objectName string, data []byte) (*storage.ObjectHandle, error)
}

func singleShotUpload(ctx context.Context, client *storage.Client,
    bucketName string, objectName string, data []byte) (*storage.ObjectHandle, error) {
    bucket := client.Bucket(bucketName)
    o := bucket.Object(objectName)
    objectWriter := o.If(storage.Conditions{DoesNotExist: true}).NewWriter(ctx)
    objectWriter.ChunkSize = len(data) + 256*KiB
    objectWriter.DisableAutoChecksum = true
    if _, err := io.Copy(objectWriter, bytes.NewBuffer(data)); err != nil {
        return o, err
    }
    return o, objectWriter.Close()
}

func resumableUpload(ctx context.Context, client *storage.Client,
    bucketName string, objectName string, data []byte) (*storage.ObjectHandle, error) {
    bucket := client.Bucket(bucketName)
    o := bucket.Object(objectName)
    objectWriter := o.If(storage.Conditions{DoesNotExist: true}).NewWriter(ctx)
    if len(data) > googleapi.DefaultUploadChunkSize {
        objectWriter.ChunkSize = googleapi.DefaultUploadChunkSize
    } else if len(data) > uploadQuantum {
        objectWriter.ChunkSize = max(2*MiB, len(data)-uploadQuantum) // using standard max helper instead of internal one
    } else {
        objectWriter.ChunkSize = uploadQuantum
    }
    if _, err := objectWriter.Write(data); err != nil {
        return o, err
    }
    return o, objectWriter.Close()
}

func appendableUpload(ctx context.Context, client *storage.Client,
    bucketName string, objectName string, data []byte) (*storage.ObjectHandle, error) {
    o := client.Bucket(bucketName).Object(objectName)
    w := o.If(storage.Conditions{DoesNotExist: true}).NewWriter(ctx)
    w.Append = true
    w.FinalizeOnClose = true
    if _, err := w.Write(data); err != nil {
        return o, err
    }
    return o, w.Close()
}

func makeUploaders(names stringFlags, bucketType string) ([]Uploader, error) {
    if bucketType == rapid {
        if len(names) > 1 || (len(names) == 1 && names[0] != appendable) {
            log.Println("Warning: uploader arguments ignored because bucket type is Rapid; using appendable")
        }
        return []Uploader{{appendable, appendableUpload}}, nil
    }

    if len(names) == 0 {
        names = append(names, singleShot)
    }

    var uploaders = make([]Uploader, 0)
    for _, name := range names {
        switch name {
        case singleShot:
            uploaders = append(uploaders, Uploader{singleShot, singleShotUpload})
        case resumable:
            uploaders = append(uploaders, Uploader{resumable, resumableUpload})
        case appendable:
            return nil, errors.New("bucket type must be Rapid to use appendable uploads")
        default:
            return nil, fmt.Errorf("unknown uploader name %s", name)
        }
    }
    return uploaders, nil
}

// --- Flag Helpers ---
type stringFlags []string

func (i *stringFlags) String() string {
    return strings.Join(*i, ",")
}

func (i *stringFlags) Set(value string) error {
    *i = append(*i, value)
    return nil
}

type intFlags []int64

func (i *intFlags) String() string {
    return fmt.Sprint(*i)
}

func (i *intFlags) Set(value string) error {
    v, err := strconv.ParseInt(value, 10, 64)
    if err != nil {
        return err
    }
    *i = append(*i, v)
    return nil
}

func fetchBucketAttrs(client *storage.Client, bucket string) (string, string, error) {
    attrs, err := client.Bucket(bucket).Attrs(context.Background())
    if err != nil {
        return "", "", err
    }
    if attrs.StorageClass == rapid {
        return rapid, attrs.Location, nil
    }
    return regional, attrs.Location, nil
}
