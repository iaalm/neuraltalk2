
require 'torch'
require 'nn'
require 'nngraph'
-- exotic things
require 'loadcaffe'
-- local imports
local utils = require 'misc.utils'
require 'misc.DataLoader'
require 'misc.LanguageModel'
local net_utils = require 'misc.net_utils'
require 'misc.optim_updates'
local threads = require 'threads'
require 'hdf5'

-------------------------------------------------------------------------------
-- Input arguments and options
-------------------------------------------------------------------------------
cmd = torch.CmdLine()
cmd:text()
cmd:text('Train an Image Captioning model')
cmd:text()
cmd:text('Options')

-- Data input settings
cmd:option('-input_h5','coco/data.h5','path to the h5file containing the preprocessed dataset')
cmd:option('-input_json','coco/data.json','path to the json file containing additional info and vocab')
--TODO: add of_cnn and img_cnn
cmd:option('-img_cnn_proto','model/VGG_ILSVRC_16_layers_deploy.prototxt','path to CNN prototxt file in Caffe format. Note this MUST be a VGGNet-16 right now.')
cmd:option('-img_cnn_model','model/VGG_ILSVRC_16_layers.caffemodel','path to CNN model file containing the weights, Caffe format. Note this MUST be a VGGNet-16 right now.')
cmd:option('-of_cnn_proto','model/vgg_16_flow_train_val_fast.prototxt','path to CNN prototxt file in Caffe format. Note this MUST be a VGGNet-16 right now.')
cmd:option('-of_cnn_model','model/vgg_16_action_flow_pretrain.caffemodel','path to CNN model file containing the weights, Caffe format. Note this MUST be a VGGNet-16 right now.')
cmd:option('-of_dir', '', 'dir of of')
cmd:option('-of_size', 10, 'of batch size')
cmd:option('-start_from', '', 'path to a model checkpoint to initialize model weights from. Empty = do not')

-- Model settings
cmd:option('-rnn_size',512,'size of the rnn in number of hidden nodes in each layer')
cmd:option('-input_encoding_size',512,'the encoding size of each token in the vocabulary, and the image.')

-- Optimization: General
cmd:option('-max_iters', -1, 'max number of iterations to run for (-1 = run forever)')
cmd:option('-batch_size',4,'what is the batch size in number of images per batch? (there will be x seq_per_img sentences)')
cmd:option('-img_per_video',4,'what is the batch size in number of images per batch? (there will be x seq_per_img sentences)')
cmd:option('-grad_clip',0.1,'clip gradients at this value (note should be lower than usual 5 because we normalize grads by both batch and seq_length)')
cmd:option('-drop_prob_lm', 0.5, 'strength of dropout in the Language Model RNN')
cmd:option('-finetune_cnn_after', -1, 'After what iteration do we start finetuning the CNN? (-1 = disable; never finetune, 0 = finetune from start)')
cmd:option('-finetune_mt_after', -1, 'After what iteration do we start finetuning the Multitask? (-1 = disable; never finetune, 0 = finetune from start)')
cmd:option('-seq_per_img',20,'number of captions to sample for each image during training. Done for efficiency since CNN forward pass is expensive. E.g. coco has 5 sents/image')
-- Optimization: for the Language Model
cmd:option('-optim','adam','what update to use? rmsprop|sgd|sgdmom|adagrad|adam')
cmd:option('-learning_rate',4e-4,'learning rate')
cmd:option('-learning_rate_decay_start', -1, 'at what iteration to start decaying learning rate? (-1 = dont)')
cmd:option('-learning_rate_decay_every', 50000, 'every how many iterations thereafter to drop LR by half?')
cmd:option('-optim_alpha',0.8,'alpha for adagrad/rmsprop/momentum/adam')
cmd:option('-optim_beta',0.999,'beta used for adam')
cmd:option('-optim_epsilon',1e-8,'epsilon that goes into denominator for smoothing')
-- Optimization: for the CNN
cmd:option('-cnn_optim','adam','optimization to use for CNN')
cmd:option('-cnn_optim_alpha',0.8,'alpha for momentum of CNN')
cmd:option('-cnn_optim_beta',0.999,'alpha for momentum of CNN')
cmd:option('-cnn_learning_rate',1e-5,'learning rate for the CNN')
cmd:option('-cnn_weight_decay', 0, 'L2 weight decay just for the CNN')

-- Evaluation/Checkpointing
cmd:option('-val_images_use', -1, 'how many images to use when periodically evaluating the validation loss? (-1 = all)')
cmd:option('-save_checkpoint_every', 2500, 'how often to save a model checkpoint?')
cmd:option('-checkpoint_path', '/media/ceph/simon/neuraltalk2/checkpoint', 'folder to save checkpoints into (empty = this folder)')
cmd:option('-language_eval', 1, 'Evaluate language as well (1 = yes, 0 = no)? BLEU/CIDEr/METEOR/ROUGE_L? requires coco-caption code from Github.')
cmd:option('-losses_log_every', 25, 'How often do we snapshot losses, for inclusion in the progress dump? (0 = disable)')

-- misc
cmd:option('-backend', 'cudnn', 'nn|cudnn')
cmd:option('-id', '', 'an id identifying this run/job. used in cross-val and appended when writing progress files')
cmd:option('-seed', 123, 'random number generator seed to use')
cmd:option('-gpuid', 0, 'which gpu to use. -1 = use CPU')
cmd:option('-num_lstm', 1, 'how many LSTM layers')
cmd:option('-mt_size', 20, 'how many LSTM layers')
cmd:option('-cnn_from', '', 'load cnn from')

cmd:text()

-------------------------------------------------------------------------------
-- Basic Torch initializations
-------------------------------------------------------------------------------
local opt = cmd:parse(arg)
torch.manualSeed(opt.seed)
torch.setdefaulttensortype('torch.FloatTensor') -- for CPU

local checkpoint_path = path.join(opt.checkpoint_path, 'model_id' .. opt.id)
if (path.exists(checkpoint_path .. '.json')) then
  print('logfile ' .. checkpoint_path .. '.json exists !')
  os.exit(1)
end

if opt.gpuid >= 0 then
  require 'cutorch'
  require 'cunn'
  if opt.backend == 'cudnn' then require 'cudnn' end
  cutorch.manualSeed(opt.seed)
  cutorch.setDevice(opt.gpuid + 1) -- note +1 because lua is 1-indexed
end

-------------------------------------------------------------------------------
-- Create the Data Loader instance
-------------------------------------------------------------------------------
local loader = DataLoader{h5_file = opt.input_h5, json_file = opt.input_json, of_dir = opt.of_dir}

-------------------------------------------------------------------------------
-- Initialize the networks
-------------------------------------------------------------------------------
local function CategoryModel()
  local model = nn.Sequential()
  model:add(nn.Linear(opt.input_encoding_size,opt.mt_size))
  return model
end
local function build_multicnn(img_cnn, optflow_cnn)
  local mcnn = nn.ParallelTable() -- output on 3*encoding 
  mcnn:add(img_cnn)
  mcnn:add(optflow_cnn)
  local scnn = nn.Sequential()
  scnn:add(mcnn)
  scnn:add(nn.JoinTable(2))
  return scnn
end

local protos = {}

local cnn_raw
if string.len(opt.start_from) > 0 then
  -- load protos from file
  print('initializing weights from ' .. opt.start_from)
  local loaded_checkpoint = torch.load(opt.start_from)
  protos = loaded_checkpoint.protos
  net_utils.unsanitize_gradients(protos.img_cnn)
  net_utils.unsanitize_gradients(protos.of_cnn)
  net_utils.unsanitize_gradients(protos.cate)
  local lm_modules = protos.lm:getModulesList()
  for k,v in pairs(lm_modules) do net_utils.unsanitize_gradients(v) end
  protos.crit = nn.LanguageModelCriterion() -- not in checkpoints, create manually
  protos.expander = nn.FeatExpander(opt.seq_per_img) -- not in checkpoints, create manually
  protos.cate_loss = nn.CrossEntropyCriterion()
else
  -- create protos from scratch
  -- intialize language model
  local lmOpt = {}
  lmOpt.vocab_size = loader:getVocabSize()
  lmOpt.input_encoding_size = opt.input_encoding_size
  lmOpt.rnn_size = opt.rnn_size
  lmOpt.num_layers = opt.num_lstm
  lmOpt.dropout = opt.drop_prob_lm
  lmOpt.seq_length = loader:getSeqLength()
  lmOpt.batch_size = opt.batch_size * opt.seq_per_img
  protos.lm = nn.LanguageModel(lmOpt)
  -- initialize the ConvNet
  local cnn_backend = opt.backend
  if opt.gpuid == -1 then cnn_backend = 'nn' end -- override to nn if gpu is disabled
  local of_cnn_raw = loadcaffe.load(opt.of_cnn_proto, opt.of_cnn_model, cnn_backend)
  protos.of_cnn = net_utils.build_of_cnn(of_cnn_raw, {batch_size = opt.batch_size, video_size = opt.of_size, encoding_size = math.ceil(opt.input_encoding_size/2), backend = cnn_backend})
  if opt.cnn_from == '' then
    local img_cnn_raw = loadcaffe.load(opt.img_cnn_proto, opt.img_cnn_model, cnn_backend)
    protos.img_cnn = net_utils.build_cnn(img_cnn_raw, {batch_size = opt.batch_size, video_size = opt.img_per_video, encoding_size = math.ceil(opt.input_encoding_size/2), backend = cnn_backend})
  else
    protos.img_cnn = torch.load(opt.cnn_from).protos.cnn
    net_utils.unsanitize_gradients(protos.img_cnn)
  end
  local cnn_raw = build_multicnn(protos.img_cnn, protos.of_cnn)
--TODO: using gpu
  protos.cnn = cnn_raw
  --protos.cnn = nn.DataParallelTable(1)
  --protos.cnn:add(cnn_raw,{1,2})
  -- initialize a special FeatExpander module that "corrects" for the batch number discrepancy 
  -- where we have multiple captions per one image in a batch. This is done for efficiency
  -- because doing a CNN forward pass is expensive. We expand out the CNN features for each sentence
  protos.expander = nn.FeatExpander(opt.seq_per_img)
  -- criterion for the language model
  protos.crit = nn.LanguageModelCriterion()
  protos.cate = CategoryModel()
  protos.cate_loss = nn.CrossEntropyCriterion()
end

-- ship everything to GPU, maybe
if opt.gpuid >= 0 then
  for k,v in pairs(protos) do v:cuda() end
end

-- flatten and prepare all model parameters to a single vector. 
-- Keep CNN params separate in case we want to try to get fancy with different optims on LM/CNN
local params, grad_params = protos.lm:getParameters()
local cnn_params, cnn_grad_params = protos.cnn:getParameters()
local mt_params, mt_grad_params = protos.cate:getParameters()
print('total number of parameters in CNN: ', cnn_params:nElement())
print('total number of parameters in LM: ', params:nElement())
print('total number of parameters in MT: ', mt_params:nElement())
assert(params:nElement() == grad_params:nElement())
assert(cnn_params:nElement() == cnn_grad_params:nElement())
assert(mt_params:nElement() == mt_grad_params:nElement())

-- construct thin module clones that share parameters with the actual
-- modules. These thin module will have no intermediates and will be used
-- for checkpointing to write significantly smaller checkpoint files
local thin_lm = protos.lm:clone()
local thin_cate = protos.cate:clone()
thin_lm.core:share(protos.lm.core, 'weight', 'bias') -- TODO: we are assuming that LM has specific members! figure out clean way to get rid of, not modular.
thin_lm.lookup_table:share(protos.lm.lookup_table, 'weight', 'bias')
local thin_img_cnn = protos.img_cnn:clone()
thin_img_cnn:share(protos.img_cnn, 'weight', 'bias')
local thin_of_cnn = protos.of_cnn:clone()
thin_of_cnn:share(protos.of_cnn, 'weight', 'bias')
-- sanitize all modules of gradient storage so that we dont save big checkpoints
net_utils.sanitize_gradients(thin_img_cnn)
net_utils.sanitize_gradients(thin_of_cnn)
net_utils.sanitize_gradients(thin_cate)
local lm_modules = thin_lm:getModulesList()
for k,v in pairs(lm_modules) do net_utils.sanitize_gradients(v) end

-- create clones and ensure parameter sharing. we have to do this 
-- all the way here at the end because calls such as :cuda() and
-- :getParameters() reshuffle memory around.
protos.lm:createClones()

collectgarbage() -- "yeah, sure why not"
-------------------------------------------------------------------------------
-- Validation evaluation
-------------------------------------------------------------------------------
local function eval_split(split, evalopt)
-- different eval
  local verbose = utils.getopt(evalopt, 'verbose', true)
  local val_images_use = utils.getopt(evalopt, 'val_images_use', true)

  protos.cnn:evaluate()
  protos.lm:evaluate()
  loader:resetIterator(split) -- rewind iteator back to first datapoint in the split
  local n = 0
  local loss_sum = 0
  local loss_evals = 0
  local predictions = {}
  local vocab = loader:getVocab()
  while true do

    -- fetch a batch of data
    local data = loader:getBatch{batch_size = opt.batch_size, video_size = opt.img_per_video, of_size = opt.of_size, split = split, seq_per_img = opt.seq_per_img}
    if data.bounds.wrapped then break end -- the split ran out of data, lets break out
    data.images = data.images:reshape(opt.batch_size*opt.img_per_video,3,256,256)
    data.images = net_utils.prepro(data.images, false, opt.gpuid >= 0) -- preprocess in place, and don't augment
    n = n + data.images:size(1)

    -- forward the model to get loss
    local feats = protos.cnn:forward{data.images,data.of:cuda()}
    local expanded_feats = protos.expander:forward(feats)
    local logprobs = protos.lm:forward{expanded_feats, data.labels}
    local loss = protos.crit:forward(logprobs, data.labels)
    loss_sum = loss_sum + loss
    loss_evals = loss_evals + 1

    -- forward the model to also get generated samples for each image
    local seq = protos.lm:sample(feats)
    local sents = net_utils.decode_sequence(vocab, seq)
    for k=1,#sents do
      local entry = {image_id = data.infos[k].id, caption = sents[k]}
      table.insert(predictions, entry)
      if verbose then
        print(string.format('image %s: %s', entry.image_id, entry.caption))
      end
    end

    -- if we wrapped around the split or used up val imgs budget then bail
    local ix0 = data.bounds.it_pos_now
    local ix1 = math.min(data.bounds.it_max, val_images_use)
    if verbose then
      print(string.format('evaluating validation performance... %d/%d (%f)', ix0-1, ix1, loss))
    end

    if loss_evals % 10 == 0 then collectgarbage() end
    if ix0 >= val_images_use and val_images_use >= 0 then break end -- we've used enough images
  end

  local lang_stats
  if opt.language_eval == 1 then
    lang_stats = net_utils.language_eval(predictions, opt.id)
  end

  return loss_sum/loss_evals, predictions, lang_stats
end
donkey = threads(1,function()  require 'misc.DataLoader' donkey_loader = DataLoader{h5_file = opt.input_h5, json_file = opt.input_json, of_dir = opt.of_dir} end)

prefetch_data = nil
-------------------------------------------------------------------------------
-- Loss function
-------------------------------------------------------------------------------
local iter = 0
local function lossFun()
  protos.cnn:training()
  protos.lm:training()
  protos.cate:training()
  grad_params:zero()
  if opt.finetune_cnn_after >= 0 and iter >= opt.finetune_cnn_after then
    cnn_grad_params:zero()
  end

  -----------------------------------------------------------------------------
  -- Forward pass
  -----------------------------------------------------------------------------
  -- get batch of data  
  donkey:synchronize()
  local data = prefetch_data
  donkey:addjob(function() return donkey_loader:getBatch{batch_size = opt.batch_size, video_size = opt.img_per_video, of_size = opt.of_size, split = 'train', seq_per_img = opt.seq_per_img} end,function(d) prefetch_data = d end)
  data.images = data.images:reshape(opt.batch_size*opt.img_per_video,3,256,256)
  data.images = net_utils.prepro(data.images, true, opt.gpuid >= 0) -- preprocess in place, do data augmentation
  data.of = data.of:cuda()
  -- data.images: Nx3x224x224 
  -- data.seq: LxM where L is sequence length upper bound, and M = N*seq_per_img

  -- forward the ConvNet on images (most work happens here)
  local feats = protos.cnn:forward{data.images, data.of}
  -- we have to expand out image features, once for each sentence
  local expanded_feats = protos.expander:forward(feats)
  -- forward the language model
  local logprobs = protos.lm:forward{expanded_feats, data.labels}
  -- forward the language model criterion
  local loss = protos.crit:forward(logprobs, data.labels)
  local cate_res = protos.cate:forward(feats)
--ugly cuda
  local cate_loss = protos.cate_loss:forward(cate_res, data.category:cuda())
  
  -----------------------------------------------------------------------------
  -- Backward pass
  -----------------------------------------------------------------------------
  -- backprop criterion
  local dlogprobs = protos.crit:backward(logprobs, data.labels)
  -- backprop language model
  local dexpanded_feats, ddummy = unpack(protos.lm:backward({expanded_feats, data.labels}, dlogprobs))
  local dcate_loss = protos.cate_loss:backward(cate_res, data.category:cuda())
  local dcate = protos.cate:backward(feats, dcate_loss)
  -- backprop the CNN, but only if we are finetuning
  if opt.finetune_cnn_after >= 0 and iter >= opt.finetune_cnn_after then
    local dfeats = protos.expander:backward(feats, dexpanded_feats)
    local dx = protos.cnn:backward({data.images,data.of}, dfeats)
  end
  if opt.finetune_mt_after >= 0 and iter >= opt.finetune_mt_after then
    local dx = protos.cnn:backward(data.images, dcate)
  end

  -- clip gradients
  -- print(string.format('claming %f%% of gradients', 100*torch.mean(torch.gt(torch.abs(grad_params), opt.grad_clip))))
  grad_params:clamp(-opt.grad_clip, opt.grad_clip)

  -- apply L2 regularization
  if opt.cnn_weight_decay > 0 then
    cnn_grad_params:add(opt.cnn_weight_decay, cnn_params)
    -- note: we don't bother adding the l2 loss to the total loss, meh.
    cnn_grad_params:clamp(-opt.grad_clip, opt.grad_clip)
  end
  -----------------------------------------------------------------------------

  -- and lets get out!
  local losses = { total_loss = loss, category_loss = cate_loss }
  return losses
end

-------------------------------------------------------------------------------
-- Main loop
-------------------------------------------------------------------------------
local loss0
local optim_state = {}
local cnn_optim_state = {}
local mt_optim_state = {}
local loss_history = {}
local val_lang_stats_history = {}
local val_loss_history = {}
local best_score
donkey:addjob(function() return donkey_loader:getBatch{batch_size = opt.batch_size, video_size = opt.img_per_video, of_size = opt.of_size, split = 'train', seq_per_img = opt.seq_per_img} end,function(d) prefetch_data = d end)
while true do  

  -- eval loss/gradient
  local losses = lossFun()
  if iter % opt.losses_log_every == 0 then loss_history[iter] = losses.total_loss end
  print(string.format('iter %d: %f\t%f', iter, losses.total_loss, losses.category_loss))

  -- save checkpoint once in a while (or on final iteration)
  if (iter % opt.save_checkpoint_every == 0 or iter == opt.max_iters) then

    -- evaluate the validation performance
    local val_loss, val_predictions, lang_stats = eval_split('validate', {val_images_use = opt.val_images_use})
    print('validation loss: ', val_loss)
    print(lang_stats)
    val_loss_history[iter] = val_loss
    if lang_stats then
      val_lang_stats_history[iter] = lang_stats
    end


    -- write a (thin) json report
    local checkpoint = {}
    checkpoint.opt = opt
    checkpoint.iter = iter
    checkpoint.loss_history = loss_history
    checkpoint.val_loss_history = val_loss_history
    checkpoint.val_predictions = val_predictions -- save these too for CIDEr/METEOR/etc eval
    checkpoint.val_lang_stats_history = val_lang_stats_history

    utils.write_json(checkpoint_path .. '.json', checkpoint)
    print('wrote json checkpoint to ' .. checkpoint_path .. '.json')

    -- write the full model checkpoint as well if we did better than ever
    local current_score
    if lang_stats then
      -- use CIDEr score for deciding how well we did
      current_score = lang_stats['CIDEr']
    else
      -- use the (negative) validation loss as a score
      current_score = -val_loss
    end
    if best_score == nil or current_score > best_score then
      best_score = current_score
      if iter > 0 then -- dont save on very first iteration
        -- include the protos (which have weights) and save to file
        local save_protos = {}
        save_protos.lm = thin_lm -- these are shared clones, and point to correct param storage
        save_protos.cate = thin_cate -- these are shared clones, and point to correct param storage
        save_protos.img_cnn = thin_img_cnn
        save_protos.of_cnn = thin_of_cnn
        checkpoint.protos = save_protos
        -- also include the vocabulary mapping so that we can use the checkpoint 
        -- alone to run on arbitrary images without the data loader
        checkpoint.vocab = loader:getVocab()
        torch.save(checkpoint_path .. '.t7', checkpoint)
        print('wrote checkpoint to ' .. checkpoint_path .. '.t7')
      end
    end
  end

  -- decay the learning rate for both LM and CNN
  local learning_rate = opt.learning_rate
  local cnn_learning_rate = opt.cnn_learning_rate
  if iter > opt.learning_rate_decay_start and opt.learning_rate_decay_start >= 0 then
    local frac = (iter - opt.learning_rate_decay_start) / opt.learning_rate_decay_every
    local decay_factor = math.pow(0.5, frac)
    learning_rate = learning_rate * decay_factor -- set the decayed rate
    cnn_learning_rate = cnn_learning_rate * decay_factor
  end

  -- perform a parameter update
  if opt.optim == 'rmsprop' then
    rmsprop(params, grad_params, learning_rate, opt.optim_alpha, opt.optim_epsilon, optim_state)
  elseif opt.optim == 'adagrad' then
    adagrad(params, grad_params, learning_rate, opt.optim_epsilon, optim_state)
  elseif opt.optim == 'sgd' then
    sgd(params, grad_params, opt.learning_rate)
  elseif opt.optim == 'sgdm' then
    sgdm(params, grad_params, learning_rate, opt.optim_alpha, optim_state)
  elseif opt.optim == 'sgdmom' then
    sgdmom(params, grad_params, learning_rate, opt.optim_alpha, optim_state)
  elseif opt.optim == 'adam' then
    adam(params, grad_params, learning_rate, opt.optim_alpha, opt.optim_beta, opt.optim_epsilon, optim_state)
  else
    error('bad option opt.optim')
  end

  -- do a cnn update (if finetuning, and if rnn above us is not warming up right now)
  if opt.finetune_cnn_after >= 0 and iter >= opt.finetune_cnn_after then
    if opt.cnn_optim == 'sgd' then
      sgd(cnn_params, cnn_grad_params, cnn_learning_rate)
    elseif opt.cnn_optim == 'sgdm' then
      sgdm(cnn_params, cnn_grad_params, cnn_learning_rate, opt.cnn_optim_alpha, cnn_optim_state)
    elseif opt.cnn_optim == 'adam' then
      adam(cnn_params, cnn_grad_params, cnn_learning_rate, opt.cnn_optim_alpha, opt.cnn_optim_beta, opt.optim_epsilon, cnn_optim_state)
    else
      error('bad option for opt.cnn_optim')
    end
  end
    if opt.cnn_optim == 'sgd' then
      sgd(mt_params, mt_grad_params, cnn_learning_rate*0.1)
    elseif opt.cnn_optim == 'sgdm' then
      sgdm(mt_params, mt_grad_params, cnn_learning_rate*0.1, opt.cnn_optim_alpha, mt_optim_state)
    elseif opt.cnn_optim == 'adam' then
      adam(mt_params, mt_grad_params, cnn_learning_rate*0.1, opt.cnn_optim_alpha, opt.cnn_optim_beta, opt.optim_epsilon, mt_optim_state)
    else
      error('bad option for opt.cnn_optim')
    end

  -- stopping criterions
  iter = iter + 1
  if iter % 10 == 0 then collectgarbage() end -- good idea to do this once in a while, i think
  if loss0 == nil then loss0 = losses.total_loss end
  if losses.total_loss > loss0 * 20 then
    print('loss seems to be exploding, quitting.')
    break
  end
  if opt.max_iters > 0 and iter >= opt.max_iters then break end -- stopping criterion

end
