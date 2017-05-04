#include "goofit/PdfBase.h"

// This is code that belongs to the PdfBase class, that is,
// it is common across all implementations. But it calls on device-side
// functions, and due to the nvcc translation-unit limitations, it cannot
// sit in its own object file; it must go in the CUDAglob.cu. So it's
// off on its own in this inline-cuda file, which GooPdf.cu
// should include.

__host__ void PdfBase::copyParams(const std::vector<double>& pars) const {
    // copyParams method performs eponymous action!

    for(unsigned int i = 0; i < pars.size(); ++i) {
        host_params[i] = pars[i];

        if(std::isnan(host_params[i])) {
            std::cout << " agh, parameter is NaN, die " << i << std::endl;
            abortWithCudaPrintFlush(__FILE__, __LINE__, "NaN in parameter");
        }
    }

    MEMCPY_TO_SYMBOL(cudaArray, host_params, pars.size()*sizeof(fptype), 0, cudaMemcpyHostToDevice);
}

__host__ void PdfBase::copyParams() {
    // Copies values of Variable objects
    std::vector<Variable*> pars = getParameters();
    std::vector<double> values;

    for(Variable* v : pars) {
        int index = v->getIndex();

        if(index >= (int) values.size())
            values.resize(index + 1);

        values[index] = v->getValue();
    }

    copyParams(values);
}

__host__ void PdfBase::copyNormFactors() const {
    MEMCPY_TO_SYMBOL(normalisationFactors, host_normalisation, totalParams*sizeof(fptype), 0, cudaMemcpyHostToDevice);
    cudaDeviceSynchronize(); // Ensure normalisation integrals are finished
}

__host__ void PdfBase::initialiseIndices(std::vector<unsigned int> pindices) {
    // Structure of the individual index array: Number of parameters, then the indices
    // requested by the subclass (which will be interpreted by the subclass kernel),
    // then the number of observables, then the observable indices. Notice that the
    // observable indices are not set until 'setIndices' is called, usually from setData;
    // here we only reserve space for them by setting totalParams.
    // This is to allow index sharing between PDFs - all the PDFs must be constructed
    // before we know what observables exist.

    if(totalParams + pindices.size() >= maxParams) {
        std::cout << "Major problem with pindices size: " << totalParams << " + " << pindices.size() << " >= " << maxParams <<
                  std::endl;
    }

    assert(totalParams + pindices.size() < maxParams);
    host_indices[totalParams] = pindices.size();

    for(int i = 1; i <= host_indices[totalParams]; ++i) {
        host_indices[totalParams+i] = pindices[i-1];
    }

    host_indices[totalParams + pindices.size() + 1] = observables.size();

    parameters = totalParams;
    totalParams += (2 + pindices.size() + observables.size());
    /*
    std::cout << "host_indices after " << getName() << " initialisation : ";
    for (int i = 0; i < totalParams; ++i) {
      std::cout << host_indices[i] << " ";
    }

    std::cout << " | "
        << parameters << " "
        << totalParams << " "
        << cudaArray << " "
        << paramIndices << " "
        << std::endl;
    */
    MEMCPY_TO_SYMBOL(paramIndices, host_indices, totalParams*sizeof(unsigned int), 0, cudaMemcpyHostToDevice);
}

__host__ void PdfBase::setData(std::vector<std::map<Variable*, fptype>>& data) {
    // Old method retained for backwards compatibility

    if(dev_event_array) {
        gooFree(dev_event_array);
        dev_event_array = 0;
    }

    setIndices();
    int dimensions = observables.size();
    numEntries = data.size();
    numEvents = numEntries;

    fptype* host_array = new fptype[data.size()*dimensions];

    for(unsigned int i = 0; i < data.size(); ++i) {
        for(Variable*  v : observables) {
            assert(data[i].find(v) != data[i].end());
            host_array[i*dimensions + v->getIndex()] = data[i][v];
        }
    }

    gooMalloc((void**) &dev_event_array, dimensions*numEntries*sizeof(fptype));
    MEMCPY(dev_event_array, host_array, dimensions*numEntries*sizeof(fptype), cudaMemcpyHostToDevice);
    MEMCPY_TO_SYMBOL(functorConstants, &numEvents, sizeof(fptype), 0, cudaMemcpyHostToDevice);
    delete[] host_array;
}

__host__ void PdfBase::recursiveSetIndices() {
    for(unsigned int i = 0; i < components.size(); ++i) {
        components[i]->recursiveSetIndices();
    }

    int numParams = host_indices[parameters];
    int counter = 0;

    for(Variable* v : observables) {
        host_indices[parameters + 2 + numParams + counter] = v->getIndex();
        GOOFIT_TRACE("{} set index of {} to {} -> host {}", getName(), v->getName(), v->index, parameters + 2 + numParams + counter)
        counter++;
    }

    generateNormRange();
}

__host__ void PdfBase::setIndices() {
    int counter = 0;

    for(Variable* v : observables) {
        v->setIndex(counter++);
    }

    recursiveSetIndices();
    MEMCPY_TO_SYMBOL(paramIndices, host_indices, totalParams*sizeof(unsigned int), 0, cudaMemcpyHostToDevice);

    //std::cout << "host_indices after " << getName() << " observable setIndices : ";
    //for (int i = 0; i < totalParams; ++i) {
    //std::cout << host_indices[i] << " ";
    //}
    //std::cout << std::endl;

}

__host__ void PdfBase::setData(UnbinnedDataSet* data) {
    if(dev_event_array) {
        gooFree(dev_event_array);
        cudaDeviceSynchronize();
        dev_event_array = 0;
        m_iEventsPerTask = 0;
    }

    setIndices();
    int dimensions = observables.size();
    numEntries = data->getNumEvents();
    numEvents = numEntries;

#ifdef GOOFIT_MPI
    //This fetches our rank and the total number of processes in the MPI call
    int myId, numProcs;
    MPI_Comm_size(MPI_COMM_WORLD, &numProcs);
    MPI_Comm_rank(MPI_COMM_WORLD, &myId);

    int perTask = numEvents/numProcs;

    //This will track for a given rank where they will start and how far they will go
    int* counts = new int[numProcs];
    int* displacements = new int[numProcs];

    for(int i = 0; i < numProcs - 1; i++)
        counts[i] = perTask;

    counts[numProcs - 1] = numEntries - perTask*(numProcs - 1);

    displacements[0] = 0;

    for(int i = 1; i < numProcs; i++)
        displacements[i] = displacements[i - 1] + counts[i - 1];

#endif

    fptype* host_array = new fptype[numEntries*dimensions];

#ifdef GOOFIT_MPI
    //This is an array to track if we need to re-index the observable
    int fixme[observables.size()];
    memset(fixme, 0, sizeof(int)*observables.size());

    for(int i = 0; i < observables.size(); i++) {
        //We are casting the observable to a CountVariable
        CountingVariable* c = dynamic_cast <CountingVariable*>(observables[i]);

        //if it is true re-index
        if(c)
            fixme[i] = 1;
    }

#endif

    //Transfer into our whole buffer
    for(int i = 0; i < numEntries; ++i) {
        for(Variable* v : observables) {
            fptype currVal = data->getValue(v, i);
            host_array[i*dimensions + v->getIndex()] = currVal;
        }
    }

#ifdef GOOFIT_MPI

    //We will go through all of the events and re-index if appropriate
    for(int i = 1; i < numProcs; i++) {
        for(int j = 0; j < counts[i]; j++) {
            for(int k = 0; k < dimensions; k++) {
                if(fixme[k] > 0)
                    host_array[(j + displacements[i])*dimensions + k] = float (j);
            }
        }
    }

    int mystart = displacements[myId];
    int myend = mystart + counts[myId];
    int mycount = myend - mystart;

    gooMalloc((void**) &dev_event_array, dimensions*mycount*sizeof(fptype));
    MEMCPY(dev_event_array, host_array + mystart*dimensions, dimensions*mycount*sizeof(fptype), cudaMemcpyHostToDevice);
    MEMCPY_TO_SYMBOL(functorConstants, &numEvents, sizeof(fptype), 0, cudaMemcpyHostToDevice);
    delete[] host_array;

    setNumPerTask(this, mycount);

    delete []counts;
    delete []displacements;
#else
    gooMalloc((void**) &dev_event_array, dimensions*numEntries*sizeof(fptype));
    MEMCPY(dev_event_array, host_array, dimensions*numEntries*sizeof(fptype), cudaMemcpyHostToDevice);
    MEMCPY_TO_SYMBOL(functorConstants, &numEvents, sizeof(fptype), 0, cudaMemcpyHostToDevice);
    delete[] host_array;
#endif
}

__host__ void PdfBase::setData(BinnedDataSet* data) {
    if(dev_event_array) {
        gooFree(dev_event_array);
        dev_event_array = 0;
        m_iEventsPerTask = 0;
    }

    setIndices();
    numEvents = 0;
    numEntries = data->getNumBins();
    int dimensions = 2 + observables.size(); // Bin center (x,y, ...), bin value, and bin volume.

    if(!fitControl->binnedFit())
        setFitControl(new BinnedNllFit());

#ifdef GOOFIT_MPI
    //This fetches our rank and the total number of processes in the MPI call
    int myId, numProcs;
    MPI_Comm_size(MPI_COMM_WORLD, &numProcs);
    MPI_Comm_rank(MPI_COMM_WORLD, &myId);

    int perTask = numEvents/numProcs;

    //This will track for a given rank where they will start and how far they will go
    int* counts = new int[numProcs];
    int* displacements = new int[numProcs];

    for(int i = 0; i < numProcs - 1; i++)
        counts[i] = perTask;

    counts[numProcs - 1] = numEntries - perTask*(numProcs - 1);

    displacements[0] = 0;

    for(int i = 1; i < numProcs; i++)
        displacements[i] = displacements[i - 1] + counts[i - 1];

#endif

    fptype* host_array = new fptype[numEntries*dimensions];

#ifdef GOOFIT_MPI
    //This is an array to track if we need to re-index the observable
    int fixme[observables.size()];
    memset(fixme, 0, sizeof(int)*observables.size());

    for(int i = 0; i < observables.size(); i++) {
        //We are casting the observable to a CountVariable
        CountingVariable* c = dynamic_cast <CountingVariable*>(observables[i]);

        //if it is true re-index
        if(c)
            fixme[i] = 1;
    }

#endif

    for(unsigned int i = 0; i < numEntries; ++i) {
        for(Variable* v : observables) {
            host_array[i*dimensions + v->getIndex()] = data->getBinCenter(v, i);
        }

        host_array[i*dimensions + observables.size() + 0] = data->getBinContent(i);
        host_array[i*dimensions + observables.size() + 1] = fitControl->binErrors() ? data->getBinError(i) : data->getBinVolume(i);
        numEvents += data->getBinContent(i);
    }

#ifdef GOOFIT_MPI

    //We will go through all of the events and re-index if appropriate
    for(int i = 1; i < numProcs; i++) {
        for(int j = 0; j < counts[j]; j++) {
            for(int k = 0; k < dimensions; k++) {
                if(fixme[k] > 0)
                    host_array[(j + displacements[i])*dimensions + k] = float (j);
            }
        }
    }

    int mystart = displacements[myId];
    int myend = mystart + counts[myId];
    int mycount = myend - mystart;

    gooMalloc((void**) &dev_event_array, dimensions*mycount*sizeof(fptype));
    MEMCPY(dev_event_array, host_array + mystart*dimensions, dimensions*mycount*sizeof(fptype), cudaMemcpyHostToDevice);
    MEMCPY_TO_SYMBOL(functorConstants, &numEvents, sizeof(fptype), 0, cudaMemcpyHostToDevice);
    delete[] host_array;

    setNumPerTask(this, mycount);

    delete []counts;
    delete []displacements;
#else
    gooMalloc((void**) &dev_event_array, dimensions*numEntries*sizeof(fptype));
    MEMCPY(dev_event_array, host_array, dimensions*numEntries*sizeof(fptype), cudaMemcpyHostToDevice);
    MEMCPY_TO_SYMBOL(functorConstants, &numEvents, sizeof(fptype), 0, cudaMemcpyHostToDevice);
    delete[] host_array;
#endif
}

__host__ void PdfBase::generateNormRange() {
    if(normRanges)
        gooFree(normRanges);

    gooMalloc((void**) &normRanges, 3*observables.size()*sizeof(fptype));

    fptype* host_norms = new fptype[3*observables.size()];
    int counter = 0; // Don't use index in this case to allow for, eg,

    // a single observable whose index is 1; or two observables with indices
    // 0 and 2. Make one array per functor, as opposed to variable, to make
    // it easy to pass MetricTaker a range without worrying about which parts
    // to use.
    for(Variable* v : observables) {
        host_norms[3*counter+0] = v->getLowerLimit();
        host_norms[3*counter+1] = v->getUpperLimit();
        host_norms[3*counter+2] = integrationBins > 0 ? integrationBins : v->getNumBins();
        counter++;
    }

    MEMCPY(normRanges, host_norms, 3*observables.size()*sizeof(fptype), cudaMemcpyHostToDevice);
    delete[] host_norms;
}

void PdfBase::clearCurrentFit() {
    totalParams = 0;
    gooFree(dev_event_array);
    dev_event_array = 0;
}

__host__ void PdfBase::printProfileInfo(bool topLevel) {
#ifdef PROFILING

    if(topLevel) {
        cudaError_t err = MEMCPY_FROM_SYMBOL(host_timeHist, timeHistogram, 10000*sizeof(fptype), 0);

        if(cudaSuccess != err) {
            std::cout << "Error on copying timeHistogram: " << cudagetErrorString(err) << std::endl;
            return;
        }

        std::cout << getName() << " : " << getFunctionIndex() << " " << host_timeHist[100*getFunctionIndex() +
                                         getParameterIndex()] << std::endl;

        for(unsigned int i = 0; i < components.size(); ++i) {
            components[i]->printProfileInfo(false);
        }
    }

#endif
}



gooError gooMalloc(void** target, size_t bytes) {
#if THRUST_DEVICE_SYSTEM!=THRUST_DEVICE_SYSTEM_CUDA
    target[0] = malloc(bytes);

    if(target[0])
        return gooSuccess;
    else
        return gooErrorMemoryAllocation;

#else
    return (gooError) cudaMalloc(target, bytes);
#endif
}

gooError gooFree(void* ptr) {
#if THRUST_DEVICE_SYSTEM!=THRUST_DEVICE_SYSTEM_CUDA
    free(ptr);
    return gooSuccess;
#else
    return (gooError) cudaFree(ptr);
#endif
}
