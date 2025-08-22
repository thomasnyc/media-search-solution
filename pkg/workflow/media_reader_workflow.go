// Copyright 2024 Google, LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package workflow

import (
	"text/template"

	"cloud.google.com/go/bigquery"
	"cloud.google.com/go/storage"
	"github.com/GoogleCloudPlatform/solutions/media/pkg/cloud"
	"github.com/GoogleCloudPlatform/solutions/media/pkg/commands"
	"github.com/GoogleCloudPlatform/solutions/media/pkg/cor"
	"google.golang.org/genai"
)

type MediaReaderWorkflow struct {
	cor.BaseCommand
	config              *cloud.Config
	bigqueryClient      *bigquery.Client
	genaiClient         *genai.Client
	genaiModel          *cloud.QuotaAwareGenerativeAIModel
	storageClient       *storage.Client
	numberOfWorkers     int
	contentTypeTemplate *template.Template
	templateByMediaType map[string]*cloud.PromptTemplate
	chain               cor.Chain
	ffprobeCommand      string
}

func (m *MediaReaderWorkflow) Execute(context cor.Context) {
	m.chain.Execute(context)
}

func (m *MediaReaderWorkflow) initializeChain() {
	const SummaryOutputParamName = "__summary_output__"
	const SceneOutputParamName = "__scene_output__"
	const MediaOutputParamName = "__media_output__"
	const MediaLengthOutputParamName = "__media_length_output__"
	const ContentTypeOutputParamName = "__content_type_output__"

	out := cor.NewBaseChain(m.GetName())

	// Convert the Message to an Object
	out.AddCommand(commands.NewMediaTriggerToGCSObject("media-trigger-to-gcs-object"))

	// Get media length
	out.AddCommand(commands.NewMediaLengthCommand("get-media-length", m.ffprobeCommand, MediaLengthOutputParamName, m.config))

	// Determine the media content type
	out.AddCommand(commands.NewMediaContentTypeCommand("get-media-content-type", m.config, m.genaiModel, m.contentTypeTemplate, ContentTypeOutputParamName))

	// Generate Summary
	out.AddCommand(commands.NewMediaSummaryCreator("generate-media-summary", m.config, m.genaiModel, m.templateByMediaType, MediaLengthOutputParamName, ContentTypeOutputParamName))

	// Convert the JSON to a struct and save to the summaryOutputParam
	out.AddCommand(commands.NewMediaSummaryJsonToStruct("convert-media-summary", SummaryOutputParamName))

	// Create the scene extraction command
	sceneExtractor := commands.NewSceneExtractor("extract-media-scenes", m.genaiModel, m.templateByMediaType, m.numberOfWorkers, ContentTypeOutputParamName)
	sceneExtractor.BaseCommand.OutputParamName = SceneOutputParamName
	out.AddCommand(sceneExtractor)

	// Assemble the output into a single media object
	out.AddCommand(commands.NewMediaAssembly("assemble-media-scenes", SummaryOutputParamName, SceneOutputParamName, MediaOutputParamName, MediaLengthOutputParamName))

	// Save media object to big query for async embedding job
	out.AddCommand(commands.NewMediaPersistToBigQuery(
		"write-to-bigquery",
		m.bigqueryClient,
		m.config.BigQueryDataSource.DatasetName,
		m.config.BigQueryDataSource.MediaTable, MediaOutputParamName))

	m.chain = out
}

func NewMediaReaderPipeline(
	config *cloud.Config,
	serviceClients *cloud.ServiceClients,
	agentModelName string,
	ffprobeCommand string) *MediaReaderWorkflow {

	templateByMediaType := make(map[string]*cloud.PromptTemplate)
	for mediaType := range config.PromptTemplates {
		systemInstruction := config.PromptTemplates[mediaType].SystemInstructions
		summaryTemplate, err := template.New("summary-template").Parse(config.PromptTemplates[mediaType].SummaryPrompt)
		if err != nil {
			panic(err)
		}
		sceneTemplate, err := template.New("scene-template").Parse(config.PromptTemplates[mediaType].ScenePrompt)
		if err != nil {
			panic(err)
		}
		templateByMediaType[mediaType] = &cloud.PromptTemplate{
			SystemInstructions: systemInstruction,
			SummaryPrompt:      summaryTemplate,
			ScenePrompt:        sceneTemplate,
		}
	}

	contenTypeTemplate, err := template.New("content-type-template").Parse(config.ContentType.PromptTemplate)
	if err != nil {
		panic(err)
	}

	pipeline := &MediaReaderWorkflow{
		BaseCommand:         *cor.NewBaseCommand("media-reader-pipeline"),
		config:              config,
		bigqueryClient:      serviceClients.BiqQueryClient,
		genaiClient:         serviceClients.GenAIClient,
		genaiModel:          serviceClients.AgentModels[agentModelName],
		storageClient:       serviceClients.StorageClient,
		numberOfWorkers:     config.Application.ThreadPoolSize,
		contentTypeTemplate: contenTypeTemplate,
		templateByMediaType: templateByMediaType,
		ffprobeCommand:      ffprobeCommand,
	}
	pipeline.initializeChain()
	return pipeline
}
